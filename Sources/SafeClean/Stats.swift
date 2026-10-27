import AppKit
import Charts
import CoreServices
import SwiftUI

// MARK: - 记录

/// 每次清理/卸载/维护都记一条，存在 ~/Library/Application Support/SafeClean/stats.json。
struct StatsEvent: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case junk, duplicates, personal, apps, maintenance

        var title: String {
            switch self {
            case .junk: L("系统垃圾", "System Junk")
            case .duplicates: L("重复文件", "Duplicates")
            case .personal: L("个人文件", "Personal Files")
            case .apps: L("应用程序", "Applications")
            case .maintenance: L("维护任务", "Maintenance")
            }
        }

        /// 清理量条里的分组
        var group: String {
            switch self {
            case .junk: L("系统垃圾", "System Junk")
            case .duplicates, .personal: L("个人文件", "Personal Files")
            case .apps: L("应用程序", "Applications")
            case .maintenance: L("维护", "Maintenance")
            }
        }
    }

    var id = UUID()
    let date: Date
    let kind: Kind
    let bytes: Int64
    let items: Int
}

@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()

    @Published private(set) var events: [StatsEvent] = []
    @Published private(set) var since: Date = .now

    private struct File: Codable {
        var since: Date
        var events: [StatsEvent]
    }

    private let url = FS.url("Library/Application Support/SafeClean/stats.json")

    private init() {
        // 改名前（MacCleaner）的旧记录搬过来
        let legacy = FS.url("Library/Application Support/MacCleaner/stats.json")
        if !FS.exists(url), FS.exists(legacy) {
            try? FS.fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FS.fm.copyItem(at: legacy, to: url)
        }
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
            events = file.events
            since = file.since
        } else {
            since = .now
            save()
        }
    }

    func record(_ kind: StatsEvent.Kind, _ result: CleanResult) {
        record(kind, bytes: result.trashedBytes + result.deletedBytes, items: result.trashedCount + result.deletedCount)
    }

    func record(_ kind: StatsEvent.Kind, bytes: Int64, items: Int) {
        guard !DebugFlags.readOnly else { return }
        guard items > 0 else { return }
        events.append(StatsEvent(date: .now, kind: kind, bytes: bytes, items: items))
        save()
    }

    private func save() {
        try? FS.fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(File(since: since, events: events)) { try? data.write(to: url, options: .atomic) }
    }

    var totalBytes: Int64 { events.reduce(0) { $0 + $1.bytes } }
    var totalItems: Int { events.reduce(0) { $0 + $1.items } }

    func bytes(group: String) -> Int64 { events.filter { $0.kind.group == group }.reduce(0) { $0 + $1.bytes } }
    func items(_ kind: StatsEvent.Kind) -> Int { events.filter { $0.kind == kind }.reduce(0) { $0 + $1.items } }

    /// 累计清理量随时间的变化（画折线用）
    var cumulative: [(Date, Int64)] {
        var sum: Int64 = 0
        var points: [(Date, Int64)] = [(since, 0)]
        for e in events.sorted(by: { $0.date < $1.date }) where e.bytes > 0 {
            sum += e.bytes
            points.append((e.date, sum))
        }
        if points.count > 1 { points.append((.now, sum)) }
        return points
    }
}

// MARK: - 健康度和建议

struct Recommendation: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let module: Module
    let action: @MainActor () -> Void
}

enum UsageInfo {
    /// Spotlight 记录的应用上次打开时间
    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

@MainActor
final class StatsModel: ObservableObject {
    @Published var unusedApps: [(AppInfo, Date)] = []
    @Published var loaded = false
    static let unusedDays = 90

    func refresh(state: AppState) async {
        if state.apps.apps.isEmpty { await state.apps.load() }
        if state.performance.memoryTotal == 0 { await state.performance.analyze() }
        let apps = state.apps.apps
        let cutoff = Date().addingTimeInterval(-Double(Self.unusedDays) * 86400)
        unusedApps = await Task.detached {
            apps.compactMap { app -> (AppInfo, Date)? in
                guard let last = UsageInfo.lastUsed(app.url), last < cutoff else { return nil }
                return (app, last)
            }
            .sorted { $0.1 < $1.1 }
        }.value
        loaded = true
    }

    struct Health {
        let title: String
        let color: Color
        let reasons: [String]
    }

    func health(state: AppState) -> Health {
        var reasons: [String] = []
        let disk = state.disk
        let freeRatio = disk.total > 0 ? Double(disk.free) / Double(disk.total) : 1
        if freeRatio < 0.1 { reasons.append(L("磁盘只剩 \(Int(freeRatio * 100))% 可用", "Only \(Int(freeRatio * 100))% of the disk is free")) }
        let mem = state.performance
        if mem.memoryTotal > 0, Double(mem.memoryUsed) / Double(mem.memoryTotal) > 0.9 { reasons.append(L("内存使用超过 90%", "Memory usage is over 90%")) }
        if state.junk.phase == .ready, state.junk.selectedSize > 2_000_000_000 {
            reasons.append(L("有 \(FS.format(state.junk.selectedSize)) 垃圾待清理", "\(FS.format(state.junk.selectedSize)) of junk waiting to be cleaned"))
        }
        if reasons.isEmpty {
            return Health(title: L("良好", "Good"), color: Color(hex: 0x5EEAD4), reasons: [L("磁盘空间充足", "Plenty of disk space"), L("内存压力正常", "Memory pressure is normal")])
        }
        return Health(title: reasons.count > 1 ? L("需要处理", "Needs Attention") : L("需要注意", "Check This"), color: Color(hex: 0xFFC46B), reasons: reasons)
    }

    func recommendations(state: AppState) -> [Recommendation] {
        var list: [Recommendation] = []
        if !unusedApps.isEmpty {
            list.append(
                Recommendation(
                    id: "unused", icon: "xmark.bin.fill", title: L("卸载不常用的应用", "Uninstall Unused Apps"),
                    detail: L("有 \(unusedApps.count) 个应用超过 \(Self.unusedDays) 天没打开过，看看还要不要。", "\(plural(unusedApps.count, "app", "apps")) haven't been opened in over \(Self.unusedDays) days. See if you still need them."), module: .applications
                ) {
                    state.apps.screen = .uninstaller
                    state.apps.selectedID = self.unusedApps.first?.0.id
                    state.module = .applications
                })
        }
        let updateNames = state.updates.updates.prefix(3).map(\.app.name).joined(separator: L("、", ", "))
        if !state.updates.updates.isEmpty {
            list.append(
                Recommendation(
                    id: "updates", icon: "arrow.down.app.fill", title: L("更新应用", "Update Apps"),
                    detail: L("\(state.updates.updates.count) 个应用有新版本：\(updateNames)。", "\(plural(state.updates.updates.count, "app", "apps")) have updates: \(updateNames)."),
                    module: .applications
                ) {
                    state.apps.screen = .updater
                    state.module = .applications
                })
        }
        switch state.junk.phase {
        case .ready where state.junk.selectedSize > 0:
            list.append(
                Recommendation(
                    id: "junk", icon: "bubbles.and.sparkles.fill", title: L("清理系统垃圾", "Clean System Junk"),
                    detail: L("上次扫描找到 \(FS.format(state.junk.selectedSize)) 可以放心清理的垃圾。", "The last scan found \(FS.format(state.junk.selectedSize)) of junk that's safe to clean."), module: .cleanup
                ) { state.module = .cleanup })
        case .idle:
            list.append(
                Recommendation(
                    id: "junk", icon: "bubbles.and.sparkles.fill", title: L("扫描系统垃圾", "Scan for System Junk"),
                    detail: L("缓存和日志会慢慢变多，定期扫一下。", "Caches and logs pile up over time. Scan now and then."), module: .cleanup
                ) { state.module = .cleanup })
        default: break
        }
        if state.performance.heavyCount > 0 {
            list.append(
                Recommendation(
                    id: "heavy", icon: "gauge.with.dots.needle.67percent", title: L("退出高耗能应用", "Quit Heavy Apps"),
                    detail: L("\(state.performance.heavyCount) 个应用各占用超过 1 GB 内存。", "\(plural(state.performance.heavyCount, "app", "apps")) are each using over 1 GB of memory."), module: .performance
                ) {
                    state.performance.screen = .heavy
                    state.module = .performance
                })
        }
        if state.disk.total > 0, Double(state.disk.free) / Double(state.disk.total) < 0.15 {
            list.append(
                Recommendation(
                    id: "space", icon: "circle.hexagongrid.fill", title: L("找出占空间的文件夹", "Find Space-Hogging Folders"),
                    detail: L("磁盘可用空间不多了，用空间透镜看看是谁占的。", "Free space is running low. Use Space Lens to see what's taking it."), module: .spaceLens
                ) { state.module = .spaceLens })
        }
        list.append(
            Recommendation(
                id: "maintenance", icon: "wrench.and.screwdriver.fill", title: L("运行维护任务", "Run Maintenance Tasks"),
                detail: L("释放内存、刷新 DNS 缓存、重置快速查看缓存。", "Free up RAM, flush the DNS cache and reset the Quick Look cache."), module: .performance
            ) {
                state.performance.screen = .maintenance
                state.module = .performance
            })
        return list
    }
}

// MARK: - 界面

struct StatsView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var state: AppState
    @ObservedObject var store = StatsStore.shared
    @ObservedObject var disk: DiskModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .lastTextBaseline) {
                    Text(L("统计数据", "Statistics")).font(.system(size: 44, weight: .bold))
                    Spacer()
                    Text(L("自 \(store.since.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: appLocale)))", "Since \(store.since.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: appLocale)))")).foregroundStyle(.white.opacity(0.65))
                }
                HStack(alignment: .top, spacing: 18) {
                    healthCard.frame(maxWidth: .infinity)
                    totalCard.frame(maxWidth: .infinity)
                    activityCard.frame(maxWidth: .infinity)
                }
                .frame(height: 330)
                HStack(alignment: .top, spacing: 18) {
                    recommendationsCard.frame(maxWidth: .infinity)
                    historyCard.frame(maxWidth: .infinity)
                }
                .frame(minHeight: 300)
            }
            .padding(.horizontal, 32)
            .padding(.top, 34)
            .padding(.bottom, 24)
        }
        .foregroundStyle(.white)
        .task { await model.refresh(state: state) }
    }

    // 健康度
    private var healthCard: some View {
        let health = model.health(state: state)
        let used = disk.total > 0 ? Double(disk.total - disk.free) / Double(disk.total) : 0
        return StatCard {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .stroke(LinearGradient(colors: [health.color, health.color.opacity(0)], startPoint: .top, endPoint: .bottom), lineWidth: 6)
                    .frame(width: 200, height: 200)
                    .blur(radius: 2)
                    .offset(x: 60, y: -40)
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 70, weight: .light))
                    .foregroundStyle(LinearGradient(colors: [.white, health.color], startPoint: .top, endPoint: .bottom))
                    .shadow(color: health.color.opacity(0.7), radius: 18)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Mac 健康度", "Mac Health")).font(.system(size: 15)).foregroundStyle(.white.opacity(0.75))
                    Text(health.title).font(.system(size: 34, weight: .bold)).foregroundStyle(health.color)
                    Text(DebugFlags.deviceName ?? Host.current().localizedName ?? L("这台 Mac", "This Mac")).font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
                    ForEach(health.reasons, id: \.self) { r in
                        Label(r, systemImage: health.title == L("良好", "Good") ? "checkmark" : "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(.top, 2)
                    Spacer()
                    HStack {
                        Text("Macintosh HD").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text(L("已用 \(FS.format(disk.total - disk.free)) / \(FS.format(disk.total))", "\(FS.format(disk.total - disk.free)) used of \(FS.format(disk.total))"))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.75))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule().fill(Color(hex: 0xC7D2FE)).frame(width: geo.size.width * used)
                        }
                    }
                    .frame(height: 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // 清理总量
    private var totalCard: some View {
        let groups: [(String, Color)] = [(L("系统垃圾", "System Junk"), Color(hex: 0x4ADE80)), (L("个人文件", "Personal Files"), Color(hex: 0x2DD4BF)), (L("应用程序", "Applications"), Color(hex: 0x60A5FA))]
        let total = max(store.totalBytes, 1)
        return StatCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("清理总量", "Total Cleaned")).font(.system(size: 15)).foregroundStyle(.white.opacity(0.75))
                Text(FS.format(store.totalBytes)).font(.system(size: 34, weight: .bold)).monospacedDigit()
                Text(store.events.isEmpty ? L("清理一次后这里会开始记录", "Starts recording after your first cleanup") : L("移到废纸篓或直接删除的总大小", "Total moved to the Trash or deleted"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                GeometryReader { geo in
                    HStack(spacing: 3) {
                        if store.totalBytes == 0 {
                            Capsule().fill(.white.opacity(0.15))
                        } else {
                            ForEach(groups, id: \.0) { name, color in
                                let b = store.bytes(group: name)
                                if b > 0 {
                                    RoundedRectangle(cornerRadius: 6).fill(color)
                                        .frame(width: max(8, (geo.size.width - 6) * Double(b) / Double(total)))
                                }
                            }
                        }
                    }
                }
                .frame(height: 22)
                .padding(4)
                .background(Capsule().fill(.white.opacity(0.08)))
                .padding(.bottom, 10)
                ForEach(groups, id: \.0) { name, color in
                    HStack {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(name).font(.system(size: 14))
                        Spacer()
                        Text(FS.format(store.bytes(group: name))).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    }
                }
            }
        }
    }

    // 清理趋势 + 各项数量
    private var activityCard: some View {
        StatCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("处理过的项目", "Items Handled")).font(.system(size: 15)).foregroundStyle(.white.opacity(0.75))
                Text(L("\(store.totalItems) 项", "\(plural(store.totalItems, "item", "items"))")).font(.system(size: 34, weight: .bold)).monospacedDigit()
                Chart {
                    ForEach(Array(store.cumulative.enumerated()), id: \.offset) { _, point in
                        AreaMark(x: .value(L("日期", "Date"), point.0), y: .value(L("累计", "Total"), Double(point.1)))
                            .foregroundStyle(LinearGradient(colors: [Color(hex: 0xA78BFA).opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value(L("日期", "Date"), point.0), y: .value(L("累计", "Total"), Double(point.1)))
                            .foregroundStyle(Color(hex: 0xC4B5FD))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 70)
                ForEach([StatsEvent.Kind.junk, .personal, .duplicates, .apps, .maintenance], id: \.self) { kind in
                    HStack {
                        Text(kind.title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text(kind == .maintenance ? L("\(store.items(kind)) 次", "\(plural(store.items(kind), "run", "runs"))") : L("\(store.items(kind)) 项", "\(plural(store.items(kind), "item", "items"))"))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // 优化建议
    private var recommendationsCard: some View {
        let recs = model.recommendations(state: state)
        return StatCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("\(recs.count) 条优化建议", "\(recs.count) Recommendations")).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if !model.loaded { ProgressView().controlSize(.small) }
                }
                ForEach(recs) { rec in
                    Button(action: rec.action) {
                        HStack(spacing: 14) {
                            Image(systemName: rec.icon)
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(LinearGradient(colors: rec.module.colors.suffix(2), startPoint: .top, endPoint: .bottom))
                                )
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.3)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rec.title).font(.system(size: 15, weight: .semibold))
                                Text(rec.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(12)
                        .glass(cornerRadius: 16, opacity: 0.07)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // 最近记录
    private var historyCard: some View {
        StatCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("最近记录", "Recent Activity")).font(.system(size: 15, weight: .semibold))
                if store.events.isEmpty {
                    Spacer()
                    Text(L("还没有记录。清理、卸载、运行维护任务后会出现在这里。", "Nothing yet. Cleanups, uninstalls and maintenance runs will show up here."))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ForEach(store.events.suffix(8).reversed()) { e in
                        HStack {
                            Text(e.date.formatted(.dateTime.month().day().hour().minute().locale(appLocale)))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                            Text(e.kind.title).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(e.kind == .maintenance ? L("\(e.items) 项任务", "\(plural(e.items, "task", "tasks"))") : L("\(e.items) 项 · \(FS.format(e.bytes))", "\(plural(e.items, "item", "items")) · \(FS.format(e.bytes))"))
                                .font(.system(size: 13))
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// 统计页的卡片外框
struct StatCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14)))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

#if DEBUG
    extension StatsStore {
        /// 截图用的示例记录，只放在内存里，不写文件
        func loadSample() {
            let day: TimeInterval = 86400
            since = Date().addingTimeInterval(-day * 23)
            events = [
                StatsEvent(date: .now.addingTimeInterval(-day * 20), kind: .junk, bytes: 4_350_000_000, items: 61),
                StatsEvent(date: .now.addingTimeInterval(-day * 14), kind: .apps, bytes: 1_200_000_000, items: 19),
                StatsEvent(date: .now.addingTimeInterval(-day * 9), kind: .duplicates, bytes: 310_000_000, items: 6),
                StatsEvent(date: .now.addingTimeInterval(-day * 5), kind: .maintenance, bytes: 0, items: 3),
                StatsEvent(date: .now.addingTimeInterval(-day * 2), kind: .junk, bytes: 820_000_000, items: 24),
                StatsEvent(date: .now.addingTimeInterval(-3600), kind: .personal, bytes: 2_410_000_000, items: 4),
            ]
        }
    }
#endif
