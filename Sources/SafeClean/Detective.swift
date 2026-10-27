import AppKit
import Charts
import SwiftUI

@MainActor
final class DetectiveModel: ObservableObject {
    enum Span: CaseIterable, Identifiable {
        case day, week, month, all

        var id: Self { self }
        var title: String {
            switch self {
            case .day: L("24 小时", "24 Hours")
            case .week: L("7 天", "7 Days")
            case .month: L("30 天", "30 Days")
            case .all: L("全部", "All")
            }
        }
        var seconds: Double? {
            switch self {
            case .day: 86400
            case .week: 7 * 86400
            case .month: 30 * 86400
            case .all: nil
            }
        }
    }

    @Published var snapshots: [SpaceSnapshot] = []
    @Published var span: Span = .day { didSet { recompute() } }
    @Published private(set) var change: SpaceChange?
    @Published var measuring = false
    @Published var measuringPath = ""
    @Published var systemItems: [SystemDataItem] = []
    @Published var loadingSystem = false
    @Published var regrowth: [CleanedEntry] = []
    @Published var backgroundEnabled = BackgroundRecorder.isEnabled
    @Published var message: String?
    @Published var spotlightSize: String?
    /// 演示脚本用：滚动到 "top" / "cards"
    @Published var scrollTarget: String?
    fileprivate(set) var appeared = false
    fileprivate(set) var isSample = false

    func appear() async {
        guard !isSample else { return }
        BackgroundRecorder.refreshIfNeeded()
        let (snaps, entries) = await Task.detached { (SpaceRecorder.loadSnapshots(), Regrowth.runChecks()) }.value
        snapshots = snaps
        regrowth = entries
        recompute()
        if !appeared {
            appeared = true
            if snapshots.last.map({ Date().timeIntervalSince($0.date) > 1800 }) ?? true { await record() }
            await inspectSystem()
        }
    }

    func record() async {
        guard !measuring else { return }
        measuring = true
        snapshots = await Task.detached(priority: .utility) { [weak self] in
            SpaceRecorder.record { path in Task { @MainActor in self?.measuringPath = path } }
        }.value
        measuring = false
        recompute()
    }

    func inspectSystem() async {
        loadingSystem = true
        systemItems = await Task.detached(priority: .utility) { SystemDataInspector.inspect() }.value
        loadingSystem = false
    }

    private func recompute() {
        let since = span.seconds.map { Date().addingTimeInterval(-$0) } ?? .distantPast
        change = SpaceComparer.compare(snapshots, since: since)
    }

    /// 图表用：所选时间段内每次记录的可用空间
    var freeSeries: [(Date, Double)] {
        let since = span.seconds.map { Date().addingTimeInterval(-$0) } ?? .distantPast
        let start = snapshots.lastIndex { $0.date <= since } ?? 0
        return snapshots[start...].map { ($0.date, Double($0.free) / 1e9) }
    }

    func setBackground(_ on: Bool) {
        BackgroundRecorder.setEnabled(on)
        backgroundEnabled = BackgroundRecorder.isEnabled
    }

    func perform(_ item: SystemDataItem, state: AppState) {
        switch item.action {
        case .none: break
        case .reveal(let url): FS.reveal([url])
        case .openURL(let url, _): NSWorkspace.shared.open(url)
        case .gotoPerformance:
            Task {
                await state.performance.analyze()
                state.performance.screen = .heavy
                state.module = .performance
            }
        case .admin(let command, _):
            Task {
                let r = await Task.detached { Shell.runAsAdmin(command, prompt: L("放心清理：\(item.title)", "SafeClean: \(item.title)")) }.value
                if item.id == "spotlight" {
                    spotlightSize = r.ok ? r.output.split(separator: "\t").first.map { "\($0)B" } : nil
                    message = r.ok ? nil : L("没有完成（可能取消了密码框）", "Not completed (the password prompt may have been cancelled)")
                } else {
                    message = r.ok ? L("已完成：\(item.title)", "Done: \(item.title)") : L("没有完成（可能取消了密码框）", "Not completed (the password prompt may have been cancelled)")
                    await inspectSystem()
                }
            }
        case .shell(let command, _):
            Task {
                let r = await Task.detached { Shell.run("/bin/sh", ["-c", command]) }.value
                message = r.status == 0 ? L("已完成：\(item.title)", "Done: \(item.title)") : L("没有完成：\(r.output.prefix(120))", "Not completed: \(r.output.prefix(120))")
                await inspectSystem()
            }
        }
    }
}

struct DetectiveView: View {
    @ObservedObject var model: DetectiveModel
    @ObservedObject var state: AppState
    private let accent = Module.detective.accent

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header.id("top")
                if let message = model.message {
                    Label(message, systemImage: "info.circle")
                        .font(.system(size: 13))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glass(cornerRadius: 12, opacity: 0.1)
                }
                changeCard
                HStack(alignment: .top, spacing: 18) {
                    systemCard.frame(maxWidth: .infinity)
                    regrowthCard.frame(maxWidth: .infinity)
                }
                .id("cards")
            }
            .padding(.horizontal, 32)
            .padding(.top, 34)
            .padding(.bottom, 24)
        }
        .onChange(of: model.scrollTarget) { _, target in
            guard let target else { return }
            withAnimation(.easeInOut(duration: 1.2)) { proxy.scrollTo(target, anchor: .top) }
        }
        }
        .foregroundStyle(.white)
        .task { await model.appear() }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("空间侦探", "Space Detective")).font(.system(size: 44, weight: .bold))
                Group {
                    if model.measuring {
                        Text(L("正在测量：\(model.measuringPath)", "Measuring: \(model.measuringPath)")).lineLimit(1).truncationMode(.middle)
                    } else if let last = model.snapshots.last {
                        Text(L("上次记录 \(last.date.formatted(Date.RelativeFormatStyle(presentation: .named, locale: appLocale)))，共记录 \(model.snapshots.count) 次", "Last recorded \(last.date.formatted(Date.RelativeFormatStyle(presentation: .named, locale: appLocale))) · \(plural(model.snapshots.count, "record", "records"))"))
                    } else {
                        Text(L("还没有记录", "No records yet"))
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Toggle(L("后台每 3 小时记录一次", "Record every 3 hours in the background"), isOn: Binding(get: { model.backgroundEnabled }, set: { model.setBackground($0) }))
                    .toggleStyle(.switch)
                    .help(L("在后台低优先级运行，不弹窗、不联网。关掉后会删除对应的启动项。", "Runs at low priority in the background, never shows a window or goes online. Turning it off removes the launch agent."))
                PillButton(title: model.measuring ? L("测量中…", "Measuring…") : L("立即记录", "Record Now"), icon: "record.circle") {
                    Task { await model.record() }
                }
                .disabled(model.measuring)
            }
        }
    }

    // MARK: 空间去哪了

    private var changeCard: some View {
        StatCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(L("空间去哪了", "Where Did My Space Go"), systemImage: "binoculars.fill").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Picker(L("时间范围", "Time range"), selection: $model.span) {
                        ForEach(DetectiveModel.Span.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320)
                }
                if let change = model.change {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(change.freeLost >= 0 ? L("少了 \(FS.format(change.freeLost))", "\(FS.format(change.freeLost)) less") : L("多出 \(FS.format(-change.freeLost))", "\(FS.format(-change.freeLost)) more"))
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(change.freeLost > 1_000_000_000 ? Color(hex: 0xFFB16B) : Color(hex: 0x6EE7B7))
                            .monospacedDigit()
                        Text(L("可用空间 · \(change.from.formatted(.dateTime.month().day().hour().minute().locale(appLocale))) → \(change.to.formatted(.dateTime.month().day().hour().minute().locale(appLocale)))", "free space · \(change.from.formatted(.dateTime.month().day().hour().minute().locale(appLocale))) → \(change.to.formatted(.dateTime.month().day().hour().minute().locale(appLocale)))"))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Chart {
                        ForEach(Array(model.freeSeries.enumerated()), id: \.offset) { _, point in
                            AreaMark(x: .value(L("时间", "Time"), point.0), yStart: .value(L("下限", "Floor"), yDomain.lowerBound), yEnd: .value(L("可用 GB", "Free GB"), point.1))
                                .foregroundStyle(LinearGradient(colors: [accent.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value(L("时间", "Time"), point.0), y: .value(L("可用 GB", "Free GB"), point.1)).foregroundStyle(accent)
                        }
                    }
                    .chartYScale(domain: yDomain)
                    .clipped()
                    .chartYAxis { AxisMarks { AxisValueLabel().foregroundStyle(.white.opacity(0.6)) } }
                    .chartXAxis { AxisMarks { AxisValueLabel().foregroundStyle(.white.opacity(0.6)) } }
                    .frame(height: 110)
                    HStack(alignment: .top, spacing: 24) {
                        changeList(title: L("哪里变大了", "What Grew"), items: change.growth.filter { $0.delta > 0 }, revealable: true, empty: L("没有明显变大的位置", "Nothing grew noticeably"))
                        changeList(
                            title: L("谁往硬盘写得最多", "Who Wrote the Most"), items: change.writers, revealable: false, empty: L("这段时间没有程序大量写入", "No program wrote much in this period"),
                            footnote: L("写入量不等于占用（包括写了又删的临时文件），用来找“谁在一直写”。系统级进程需要管理员权限才看得到。", "Bytes written isn't the same as space used (it includes temp files written then deleted) — it shows who keeps writing. System processes need admin rights to see."))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.snapshots.isEmpty ? L("正在做第一次记录…", "Taking the first record…") : L("需要至少两次记录才能对比", "Needs at least two records to compare"))
                            .font(.system(size: 20, weight: .semibold))
                        Text(L("每次打开这个页面都会记一次（间隔超过 30 分钟时）。打开右上角的后台记录，就算不开应用也会每 3 小时记一次，下次空间突然变少时能直接看到是谁占的。", "A record is taken each time you open this page (if 30+ minutes have passed). Turn on background recording at the top right to record every 3 hours even when the app is closed — next time space suddenly disappears, you'll see who took it."))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.vertical, 20)
                }
            }
        }
    }

    private func changeList(title: String, items: [SpaceChange.Item], revealable: Bool, empty: String, footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            if items.isEmpty {
                Text(empty).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            }
            ForEach(items.prefix(8)) { item in
                HStack(spacing: 8) {
                    Text(item.title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("+\(FS.format(item.delta))").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    if revealable {
                        Button {
                            FS.reveal([URL(fileURLWithPath: (item.key as NSString).expandingTildeInPath)])
                        } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                    }
                }
                .help(item.key)
            }
            if let footnote {
                Text(footnote).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 纵轴只覆盖实际数据范围，变化才看得出来
    private var yDomain: ClosedRange<Double> {
        let values = model.freeSeries.map(\.1)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.2, 1)
        return (lo - pad)...(hi + pad)
    }

    // MARK: 系统数据拆解

    private var systemCard: some View {
        StatCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L("系统数据里是什么", "What's in System Data"), systemImage: "cpu").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    if model.loadingSystem { ProgressView().controlSize(.small) }
                }
                Text(L("“设置 → 存储空间”里的“系统数据”是个大杂烩，这里把能找到的部分拆开说清楚。", "\"System Data\" in Settings → Storage is a catch-all. Here are the parts we can identify, explained."))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                ForEach(model.systemItems) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).frame(width: 22)
                            Text(item.title).font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text(sizeText(item)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        }
                        Text(item.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text(item.safe).font(.system(size: 12, weight: .medium)).foregroundStyle(Color(hex: 0x86EFAC))
                            Spacer()
                            if let label = actionLabel(item.action) {
                                Button(label) { model.perform(item, state: state) }.buttonStyle(.link)
                            }
                        }
                    }
                    .padding(12)
                    .glass(cornerRadius: 14, opacity: 0.06)
                }
            }
        }
    }

    private func sizeText(_ item: SystemDataItem) -> String {
        if item.id == "spotlight", let s = model.spotlightSize { return s }
        return item.size.map(FS.format) ?? "—"
    }

    private func actionLabel(_ action: SystemDataItem.Action) -> String? {
        switch action {
        case .none: nil
        case .reveal: L("在 Finder 中显示", "Show in Finder")
        case .openURL(_, let label), .admin(_, let label), .shell(_, let label): label
        case .gotoPerformance: L("查看占内存的应用", "See Memory-Hungry Apps")
        }
    }

    // MARK: 白清检测

    private var regrowthCard: some View {
        let checked = model.regrowth.filter { $0.latest != nil }
        let pending = model.regrowth.filter { $0.latest == nil }
        let pointless = checked.filter { ($0.ratio ?? 0) >= Regrowth.pointlessRatio }.sorted { $0.size > $1.size }
        let cleaned = checked.reduce(0) { $0 + $1.size }
        let regrown = checked.reduce(0) { $0 + min($1.latest?.size ?? 0, $1.size) }
        return StatCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L("白清检测", "Pointless Cleanup Check"), systemImage: "arrow.uturn.backward.circle").font(.system(size: 17, weight: .semibold))
                Text(L("清理后过 1 天、7 天再量一次。很快长回来的缓存，清了也腾不出空间，以后在“清理”里默认不勾。", "Cleaned items are re-measured after 1 and 7 days. Caches that grow right back free no space, so Cleanup stops selecting them by default."))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                if checked.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pending.isEmpty ? L("还没有可复查的清理", "Nothing to re-check yet") : L("\(pending.count) 项等待复查", "\(plural(pending.count, "item", "items")) waiting to be re-checked")).font(.system(size: 20, weight: .semibold))
                        Text(pending.isEmpty ? L("在“清理”或“智能呵护”里清理一次，这里会开始跟踪。", "Clean something in Cleanup or Smart Care and tracking starts here.") : L("最早的一项会在清理满一天后复查（打开这个页面或后台记录时）。", "The first check happens a day after cleaning (when you open this page or a background record runs)."))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                } else {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading) {
                            Text(FS.format(cleaned)).font(.system(size: 26, weight: .bold)).monospacedDigit()
                            Text(L("复查过的清理量", "Cleaned & re-checked")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                        }
                        VStack(alignment: .leading) {
                            Text(FS.format(regrown)).font(.system(size: 26, weight: .bold)).monospacedDigit()
                                .foregroundStyle(Color(hex: 0xFFB16B))
                            Text(L("又长回来了（\(cleaned > 0 ? Int(Double(regrown) / Double(cleaned) * 100) : 0)%）", "Grew back (\(cleaned > 0 ? Int(Double(regrown) / Double(cleaned) * 100) : 0)%)"))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    Text(pointless.isEmpty ? L("没有发现白清的项目", "No pointless cleanups found") : L("白清的项目（以后默认不勾）", "Pointless cleanups (unselected from now on)"))
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.top, 4)
                    ForEach(pointless.prefix(10)) { entry in
                        HStack {
                            Text(FS.abbreviate(entry.path)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(FS.format(entry.size)) → \(FS.format(entry.latest?.size ?? 0))")
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                        }
                    }
                    if !pending.isEmpty {
                        Text(L("另有 \(pending.count) 项等待复查", "\(pending.count) more waiting to be re-checked")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
    }
}

#if DEBUG
    extension DetectiveModel {
        /// 截图用：几次示例记录 + 示例白清结果，系统数据用真实检测
        func loadSample() async {
            appeared = true
            isSample = true
            let now = Date()
            func snap(_ hoursAgo: Double, free: Double, docker: Double, wechat: Double, written: [String: Double]) -> SpaceSnapshot {
                SpaceSnapshot(
                    date: now.addingTimeInterval(-hoursAgo * 3600), free: Int64(free * 1e9),
                    locations: [
                        "~/Library/Containers/com.docker.docker": Int64(docker * 1e9),
                        "~/Library/Containers/com.tencent.xinWeChat": Int64(wechat * 1e9), "~/Downloads": 10_800_000_000,
                    ],
                    processes: Dictionary(uniqueKeysWithValues: written.map { ("1:\($0.key)", SpaceSnapshot.Proc(name: $0.key, written: UInt64($0.value * 1e9))) }))
            }
            snapshots = [
                snap(26, free: 181, docker: 18, wechat: 31, written: ["com.docker.backend": 2, "WeChat": 1, "backupd": 0.5]),
                snap(14, free: 168, docker: 29, wechat: 33, written: ["com.docker.backend": 14, "WeChat": 3.4, "backupd": 0.5]),
                snap(6, free: 160, docker: 33, wechat: 36.5, written: ["com.docker.backend": 19, "WeChat": 7, "backupd": 4]),
                snap(0, free: 152, docker: 39, wechat: 38, written: ["com.docker.backend": 26, "WeChat": 9.2, "backupd": 4.1]),
            ]
            span = .day
            regrowth = [
                CleanedEntry(path: FS.url("Library/Caches/Codex").path, size: 2_790_000_000, date: now.addingTimeInterval(-3 * 86400), after1d: 2_610_000_000),
                CleanedEntry(path: FS.url("Library/Caches/Google").path, size: 107_000_000, date: now.addingTimeInterval(-3 * 86400), after1d: 98_000_000),
                CleanedEntry(path: FS.url(".npm/_cacache").path, size: 416_000_000, date: now.addingTimeInterval(-3 * 86400), after1d: 12_000_000),
                CleanedEntry(path: FS.url("Library/Logs/CreativeCloud").path, size: 22_000_000, date: now.addingTimeInterval(-3 * 86400), after1d: 1_000_000),
            ]
            await inspectSystem()
        }
    }
#endif
