import AppKit
import SwiftUI

struct AppInfo: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleName: String
    let bundleID: String
    let version: String
    var size: Int64? = nil

    var id: URL { url }
}

enum AppScanner {
    /// 列出 /Applications 和 ~/Applications（含一层子目录）里的第三方应用。
    static func listApps() -> [AppInfo] {
        var found: [URL] = []
        for root in [URL(fileURLWithPath: "/Applications"), FS.url("Applications")] {
            for child in FS.children(of: root) {
                if child.pathExtension == "app" {
                    found.append(child)
                } else if FS.isDirectory(child) {
                    found += FS.children(of: child).filter { $0.pathExtension == "app" }
                }
            }
        }
        let me = Bundle.main.bundleIdentifier
        return found.compactMap { url -> AppInfo? in
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                let id = info["CFBundleIdentifier"] as? String,
                !id.hasPrefix("com.apple."), id != me
            else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            return AppInfo(
                url: url, name: name,
                bundleName: (info["CFBundleName"] as? String) ?? name,
                bundleID: id,
                version: (info["CFBundleShortVersionString"] as? String) ?? "—")
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 应用包里所有带 bundle id 的组件：主程序、登录项、菜单栏助手、扩展。
    /// 它们各自有自己的容器和偏好设置，卸载时都要算进来。
    static func bundleIDs(in app: AppInfo) -> [String] {
        var ids = [app.bundleID]
        let contents = app.url.appendingPathComponent("Contents")
        guard let e = FS.fm.enumerator(at: contents, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return ids }
        for case let url as URL in e {
            if url.lastPathComponent == "Frameworks" || url.lastPathComponent == "Resources" {
                e.skipDescendants()
                continue
            }
            guard ["app", "appex", "xpc"].contains(url.pathExtension) else { continue }
            if let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                let id = info["CFBundleIdentifier"] as? String, !ids.contains(id)
            {
                ids.append(id)
            }
        }
        return ids
    }

    /// 从代码签名里读 App Group（com.apple.security.application-groups），对应 ~/Library/Group Containers 下的目录。
    static func appGroups(of url: URL) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dict = info as? [String: Any],
            let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    /// 启动代理按 plist 内容匹配：Label、AssociatedBundleIdentifiers，或可执行文件在应用包里。
    static func launchAgentMatches(_ plist: URL, ids: [String], appPath: String) -> Bool {
        if ids.contains(where: { plist.lastPathComponent.hasPrefix($0) }) { return true }
        guard let d = NSDictionary(contentsOf: plist) as? [String: Any] else { return false }
        let label = d["Label"] as? String ?? ""
        let associated = (d["AssociatedBundleIdentifiers"] as? [String]) ?? (d["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        let program = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first ?? ""
        return ids.contains(where: { label.hasPrefix($0) }) || !Set(associated).isDisjoint(with: ids)
            || program.hasPrefix(appPath + "/")
    }

    /// 按 bundle id、应用名、App Group 和启动代理在 ~/Library 里找残留文件。
    static func leftovers(for app: AppInfo) -> [JunkItem] {
        let lib = FS.url("Library")
        let ids = bundleIDs(in: app)
        var candidates: [URL] = []
        func add(_ rel: String) { candidates.append(lib.appendingPathComponent(rel)) }

        for id in ids {
            for base in ["Application Support", "Caches", "Logs", "Containers", "HTTPStorages", "WebKit", "Application Scripts"] {
                add("\(base)/\(id)")
            }
            add("Preferences/\(id).plist")
            add("Saved Application State/\(id).savedState")
            add("HTTPStorages/\(id).binarycookies")
            add("Cookies/\(id).binarycookies")
            candidates += FS.children(of: lib.appendingPathComponent("Preferences/ByHost")).filter {
                $0.lastPathComponent.hasPrefix(id + ".")
            }
        }
        for name in Set([app.name, app.bundleName]) where name.count >= 3 {
            for base in ["Application Support", "Caches", "Logs"] { add("\(base)/\(name)") }
        }
        candidates += FS.children(of: lib.appendingPathComponent("LaunchAgents")).filter {
            $0.pathExtension == "plist" && launchAgentMatches($0, ids: ids, appPath: app.url.path)
        }

        // 只属于这个应用的 App Group 默认勾选；和别的应用共享的（比如旧版本）默认不勾
        let groups = appGroups(of: app.url)
        var shared = Set<String>()
        for group in groups {
            let url = lib.appendingPathComponent("Group Containers/\(group)")
            candidates.append(url)
            if !ids.contains(where: { group.contains($0) }) { shared.insert(url.path) }
        }

        var seen = Set<String>()
        return candidates
            .filter { FS.exists($0) && seen.insert($0.path).inserted }
            .map { url in
                var item = JunkItem(url: url, name: FS.abbreviate(url.path), size: FS.size(of: url), selected: true)
                if shared.contains(url.path) {
                    item.selected = false
                    item.note = "共享"
                }
                return item
            }
            .sorted { $0.size > $1.size }
    }
}

@MainActor
final class AppsModel: ObservableObject {
    enum Screen { case intro, scanning, overview, uninstaller, updater }

    @Published var screen: Screen = .intro
    @Published var apps: [AppInfo] = []
    @Published var selectedID: AppInfo.ID?
    @Published var leftovers: [JunkItem] = []
    @Published var loadingLeftovers = false
    @Published var loading = false
    @Published var search = ""
    @Published var sortBySize = false
    @Published var message: String?
    @Published private var runningTick = 0
    private var sizeTask: Task<Void, Never>?
    private var leftoverTask: Task<Void, Never>?

    var selectedApp: AppInfo? { apps.first { $0.id == selectedID } }

    var visibleApps: [AppInfo] {
        let filtered = search.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search)
        }
        return sortBySize ? filtered.sorted { ($0.size ?? 0) > ($1.size ?? 0) } : filtered
    }

    var totalSize: Int64 { apps.reduce(0) { $0 + ($1.size ?? 0) } }

    /// 读出应用列表后立即返回，体积在后台慢慢算。
    func load() async {
        loading = true
        sizeTask?.cancel()
        let list = await Task.detached(priority: .userInitiated) { AppScanner.listApps() }.value
        apps = list
        loading = false
        sizeTask = Task {
            for app in list {
                if Task.isCancelled { return }
                let size = await Task.detached(priority: .utility) { FS.size(of: app.url) }.value
                if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].size = size }
            }
        }
    }

    func loadLeftovers() {
        leftoverTask?.cancel()
        leftovers = []
        message = nil
        guard let app = selectedApp else { return }
        loadingLeftovers = true
        leftoverTask = Task {
            let items = await Task.detached(priority: .userInitiated) { AppScanner.leftovers(for: app) }.value
            guard !Task.isCancelled else { return }
            leftovers = items
            loadingLeftovers = false
        }
    }

    func isRunning(_ app: AppInfo) -> Bool {
        _ = runningTick
        return !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    func quit(_ app: AppInfo) {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).forEach { $0.terminate() }
        Task {
            for _ in 0..<10 where isRunning(app) {
                try? await Task.sleep(for: .milliseconds(500))
                runningTick += 1
            }
        }
    }

    /// 应用本体交给 Finder 移到废纸篓（需要时会弹出管理员密码框），残留文件直接移到废纸篓。
    func uninstall(_ app: AppInfo) {
        guard !isRunning(app) else {
            message = "请先退出 \(app.name) 再卸载。"
            return
        }
        let targets = leftovers.filter(\.selected).map { Cleaner.Target(url: $0.url, size: $0.size, permanent: false) }
        NSWorkspace.shared.recycle([app.url]) { _, error in
            Task { @MainActor in
                if let error {
                    self.message = "没能移除 \(app.name)：\(error.localizedDescription)"
                    return
                }
                let r = await Task.detached(priority: .userInitiated) { Cleaner.perform(targets) }.value
                StatsStore.shared.record(.apps, bytes: (app.size ?? 0) + r.trashedBytes, items: 1 + r.trashedCount)
                self.apps.removeAll { $0.id == app.id }
                self.selectedID = nil
                var text = "已将 \(app.name) 和 \(r.trashedCount) 项残留文件移到废纸篓（共 \(FS.format((app.size ?? 0) + r.trashedBytes))）。"
                if !r.failures.isEmpty { text += " \(r.failures.count) 项残留没能移除。" }
                self.message = text
            }
        }
    }
}

// MARK: - 界面

struct ApplicationsView: View {
    @ObservedObject var apps: AppsModel
    @ObservedObject var updates: UpdatesModel
    @ObservedObject var disk: DiskModel
    private let module = Module.applications

    var body: some View {
        Group {
            switch apps.screen {
            case .intro:
                VStack(spacing: 0) {
                    StageTopBar(title: module.title)
                    ModuleIntro(module: module) { scan() }
                }
            case .scanning:
                VStack(spacing: 0) {
                    StageTopBar(title: module.title)
                    ScanningStage(
                        module: module, title: "正在检查应用…",
                        detail: updates.checking ? "检查更新：\(updates.checked) / \(updates.checkable)" : "读取已安装的应用",
                        progress: updates.checkable > 0 ? Double(updates.checked) / Double(updates.checkable) : nil, stop: nil)
                }
            case .overview:
                overview
            case .uninstaller:
                UninstallerPanel(model: apps) { apps.screen = .overview }
            case .updater:
                UpdaterPanel(updates: updates, recheck: { Task { await updates.check(apps: apps.apps) } }) { apps.screen = .overview }
            }
        }
        .onChange(of: apps.apps.count) { _, _ in disk.refresh() }
    }

    private func scan() {
        apps.screen = .scanning
        Task {
            await apps.load()
            await updates.check(apps: apps.apps)
            apps.screen = .overview
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            StageTopBar(leadingTitle: "重新开始", leadingAction: { apps.screen = .intro }, title: module.title)
            StageLayout(module: module, symbol: module.heroSymbol) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(apps.apps.count) 个应用").font(.system(size: 40, weight: .bold))
                    Text(updates.updates.isEmpty ? "检查过的应用都是最新版本。" : "\(updates.updates.count) 个应用有新版本可以装。")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.78))
                    ActionTile(
                        icon: "xmark.bin.fill", title: "卸载程序",
                        value: "\(apps.apps.count) 个应用 · \(FS.format(apps.totalSize))", accent: module.accent
                    ) { apps.screen = .uninstaller }
                    ActionTile(
                        icon: "arrow.down.app.fill", title: "更新程序",
                        value: updates.updates.isEmpty ? "检查了 \(updates.checkable) 个，没有可用更新" : "\(updates.updates.count) 个可更新",
                        accent: module.accent, highlight: !updates.updates.isEmpty
                    ) { apps.screen = .updater }
                }
            } bottom: {
                Color.clear
            }
        }
    }
}

/// 可点击的玻璃卡片：图标 + 标题 + 数值 + 箭头
struct ActionTile: View {
    let icon: String
    let title: String
    let value: String
    let accent: Color
    var highlight = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.opacity(0.5)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(value).font(.system(size: 13)).foregroundStyle(.white.opacity(highlight ? 0.95 : 0.7)).monospacedDigit()
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.6))
            }
            .padding(14)
            .glass(cornerRadius: 16, opacity: hovering ? 0.16 : 0.09)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 玻璃风格的搜索框
struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
            TextField(placeholder, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glass(cornerRadius: 10, opacity: 0.1)
    }
}

struct UninstallerPanel: View {
    @ObservedObject var model: AppsModel
    let back: () -> Void
    @State private var confirming = false
    private let accent = Module.applications.accent

    var body: some View {
        DetailFrame(title: "卸载程序", back: back) {
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        SearchField(placeholder: "搜索应用", text: $model.search)
                        Picker("排序", selection: $model.sortBySize) {
                            Text("名称").tag(false)
                            Text("大小").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 100)
                    }
                    .padding([.horizontal, .top], 12)
                    List(model.visibleApps, selection: $model.selectedID) { app in
                        AppRow(app: app).listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
                .frame(width: 320)
                Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
                if let app = model.selectedApp {
                    AppDetail(app: app, model: model)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "hand.point.left.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.5))
                        Text("从左边选一个应用").font(.system(size: 16, weight: .semibold))
                        Text("卸载时会把应用和它留在资源库里的文件一起移到废纸篓。")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } footer: {
            if let message = model.message {
                Label(message, systemImage: "info.circle").font(.system(size: 13)).lineLimit(2)
            } else if let app = model.selectedApp {
                Text("\(app.name)：共 \(FS.format(uninstallSize(app)))").foregroundStyle(.white.opacity(0.75)).monospacedDigit()
            }
            Spacer()
            if let app = model.selectedApp {
                if model.isRunning(app) {
                    Label("正在运行", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFFC46B))
                    PillButton(title: "退出应用") { model.quit(app) }
                }
                ActionCapsule(title: "卸载", accent: Color(hex: 0xFF5D6C), disabled: model.isRunning(app) || model.loadingLeftovers) {
                    confirming = true
                }
            }
        }
        .onChange(of: model.selectedID) { _, _ in model.loadLeftovers() }
        .onAppear { if model.selectedApp != nil && model.leftovers.isEmpty { model.loadLeftovers() } }
        .alert("卸载 \(model.selectedApp?.name ?? "")？", isPresented: $confirming) {
            Button("卸载", role: .destructive) { if let app = model.selectedApp { model.uninstall(app) } }
            Button("取消", role: .cancel) {}
        } message: {
            if let app = model.selectedApp {
                Text("应用和 \(model.leftovers.filter(\.selected).count) 项残留文件（共 \(FS.format(uninstallSize(app)))）会被移到废纸篓，需要时可以恢复。")
            }
        }
    }

    private func uninstallSize(_ app: AppInfo) -> Int64 {
        (app.size ?? 0) + model.leftovers.filter(\.selected).reduce(0) { $0 + $1.size }
    }
}

struct AppRow: View {
    let app: AppInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Text(app.version).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(app.size.map(FS.format) ?? "…")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct AppDetail: View {
    let app: AppInfo
    @ObservedObject var model: AppsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.system(size: 24, weight: .bold))
                    Text("\(app.bundleID)  ·  版本 \(app.version)")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65))
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(18)
            List {
                ListHeader("应用本体")
                HStack {
                    Image(systemName: "app.dashed").frame(width: 18)
                    Text(FS.abbreviate(app.url.path)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(app.size.map(FS.format) ?? "计算中…").monospacedDigit().foregroundStyle(.secondary)
                    Button {
                        FS.reveal([app.url])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                }
                .listRowBackground(Color.clear)
                ListHeader("残留文件")
                if model.loadingLeftovers {
                    ProgressView().controlSize(.small).listRowBackground(Color.clear)
                } else if model.leftovers.isEmpty {
                    Text("资源库里没有找到这个应用的残留文件").foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
                ForEach($model.leftovers) { $item in
                    ItemRow(item: $item).listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

struct UpdaterPanel: View {
    @ObservedObject var updates: UpdatesModel
    let recheck: () -> Void
    let back: () -> Void

    var body: some View {
        DetailFrame(title: "更新程序", back: back) {
            if updates.checking {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("检查中：\(updates.checked) / \(updates.checkable)").monospacedDigit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if updates.updates.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(Color(hex: 0x4ADE80))
                    Text("都是最新版本").font(.system(size: 18, weight: .semibold))
                    Text("检查了 \(updates.checkable) 个用 Sparkle 自动更新或来自 App Store 的应用。其他应用请用它们自带的更新方式。")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(updates.updates) { update in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: update.app.url.path))
                            .resizable()
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.app.name).font(.system(size: 15, weight: .semibold))
                            Text("当前 \(update.installed)  →  新版 \(update.latest)")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.7))
                                .monospacedDigit()
                        }
                        Text(update.source == .appStore ? "App Store" : "自动更新")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                        Spacer()
                        if let notes = update.notesURL {
                            Button("更新说明") { NSWorkspace.shared.open(notes) }.buttonStyle(.link)
                        }
                        PillButton(title: update.source == .appStore ? "去 App Store" : "打开并更新", prominent: true) {
                            updates.open(update)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        } footer: {
            if let date = updates.lastChecked {
                Text("上次检查：\(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            PillButton(title: "重新检查", icon: "arrow.clockwise", action: recheck)
        }
    }
}

/// 列表里的小标题（透明背景，代替系统列表的黑色分组栏）
struct ListHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.top, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
