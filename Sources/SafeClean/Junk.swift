import AppKit
import SwiftUI

// MARK: - 规则

struct JunkRule: Sendable {
    enum Source: Sendable {
        case contents(String)  // 目录下的每个子项是一条可清理项目
        case item(String)  // 目录本身作为一条项目
        case containers(String)  // ~/Library/Containers/*/<子路径> 下的每个子项（沙盒应用）
        case electronCaches  // Electron 应用的 Chromium 缓存
        case brokenLaunchAgents  // 指向已不存在程序的启动代理
        case brokenPreferences  // 解析不了的偏好设置文件
        /// 某个应用的固定缓存目录；路径里的 * 匹配任意子目录（比如每个账号一个）
        case appCache(name: String, owner: String, path: String)
        /// 目录下除了最近访问的那一个以外的子项（旧版本缓存）
        case allButLatest(name: String, owner: String, path: String)
    }

    let id: String
    let title: String
    let detail: String
    let icon: String
    let sources: [Source]
    var exclude: Set<String> = []
    var selectedByDefault = true
    var permanent = false
    var minimumSize: Int64 = 1  // 比这个小的项目不列出
}

enum JunkRules {
    /// 测试/自动化工具下载的浏览器内核。放在缓存目录里，但删掉后要重新下载几百 MB，
    /// 用到它的工具在重新下载前会直接报错，所以默认不勾选。目录名 → (工具名, 重新下载的命令)
    static let browserEngines: [String: (tool: String, reinstall: String)] = [
        "ms-playwright": ("Playwright", "npx playwright install"),
        "ms-playwright-go": ("Playwright for Go", "go run github.com/playwright-community/playwright-go/cmd/playwright install"),
        "Cypress": ("Cypress", "npx cypress install"),
        "puppeteer": ("Puppeteer", "npx puppeteer browsers install chrome"),
    ]

    static let all: [JunkRule] = [
        JunkRule(
            id: "caches", title: "应用缓存",
            detail: "应用为加速启动保存的缓存（含沙盒应用容器里的），删除后会按需重新生成。正在运行的应用、Playwright 等工具下载的浏览器内核默认不勾选。",
            icon: "archivebox",
            sources: [
                .contents("Library/Caches"), .containers("Data/Library/Caches"),
                .allButLatest(
                    name: "照片旧缓存", owner: "com.apple.Photos",
                    path: "Library/Containers/com.apple.Photos/Data/Library/Application Support/Photos Desktop/0"),
            ],
            exclude: [
                "com.apple.bird", "CloudKit", "com.apple.akd", "FamilyCircle", "com.apple.HomeKit",
                "com.apple.containermanagerd", "com.apple.ap.adprivacyd", Bundle.main.bundleIdentifier ?? "",
            ]),
        JunkRule(
            id: "electron", title: "Electron 应用缓存",
            detail: "Slack、Discord、VS Code 这类 Electron 应用自带浏览器内核的网页缓存。",
            icon: "globe", sources: [.electronCaches]),
        JunkRule(
            id: "logs", title: "日志文件", detail: "系统和应用写下的运行日志与崩溃报告。小于 10 KB 的不列出。",
            icon: "doc.text", sources: [.contents("Library/Logs"), .containers("Data/Library/Logs")],
            minimumSize: 10_241),
        JunkRule(
            id: "broken", title: "失效的启动项和偏好设置",
            detail: "应用删掉后留下的启动代理（指向的程序已不存在），以及已经损坏、读不出来的偏好设置文件。",
            icon: "bandage", sources: [.brokenLaunchAgents, .brokenPreferences], minimumSize: 0),
        JunkRule(
            id: "media", title: "聊天和影音应用缓存",
            detail: "微信聊天临时文件、QQ 音乐、腾讯视频、优酷、Telegram、Spotify、Adobe 的缓存。里面可能有聊天收到的图片文件或离线下载的内容，默认不勾选。",
            icon: "bubble.left.and.bubble.right",
            sources: [
                .appCache(
                    name: "微信", owner: "com.tencent.xinWeChat",
                    path: "Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat/2.0b4.0.9/*/Message/MessageTemp"),
                .appCache(
                    name: "QQ 音乐", owner: "com.tencent.QQMusicMac",
                    path: "Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iMusic"),
                .appCache(
                    name: "腾讯视频（已下载视频）", owner: "com.tencent.tenvideo",
                    path: "Library/Containers/com.tencent.tenvideo/Data/Library/Application Support/Download/video"),
                .appCache(
                    name: "优酷播放缓存", owner: "com.youku.mac",
                    path: "Library/Containers/com.youku.mac/Data/Documents/YTCORE_PLAYER_CACHE"),
                .appCache(
                    name: "Telegram", owner: "ru.keepcoder.Telegram",
                    path: "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/*/account-*/postbox/media"),
                .appCache(
                    name: "Telegram Desktop", owner: "org.telegram.desktop",
                    path: "Library/Application Support/Telegram Desktop/tdata/user_data"),
                .appCache(
                    name: "Telegram Desktop（App Store 版）", owner: "org.telegram.desktop",
                    path: "Library/Containers/org.telegram.desktop/Data/Library/Application Support/Telegram Desktop/tdata/user_data"),
                .appCache(
                    name: "Spotify", owner: "com.spotify.client",
                    path: "Library/Application Support/Spotify/PersistentCache/Storage"),
                .appCache(
                    name: "Adobe 媒体缓存", owner: "com.adobe.PremierePro",
                    path: "Library/Application Support/Adobe/Common/Media Cache Files"),
            ],
            selectedByDefault: false),
        JunkRule(
            id: "xcode", title: "Xcode 垃圾", detail: "DerivedData 编译产物、旧设备调试符号、文档缓存和模拟器缓存。",
            icon: "hammer",
            sources: [
                .contents("Library/Developer/Xcode/DerivedData"),
                .contents("Library/Developer/Xcode/iOS DeviceSupport"),
                .contents("Library/Developer/Xcode/macOS DeviceSupport"),
                .contents("Library/Developer/Xcode/watchOS DeviceSupport"),
                .contents("Library/Developer/Xcode/tvOS DeviceSupport"),
                .item("Library/Developer/Xcode/DocumentationCache"),
                .item("Library/Developer/Xcode/iOS Device Logs"),
                .item("Library/Developer/CoreSimulator/Caches"),
            ]),
        JunkRule(
            id: "dev", title: "开发工具缓存", detail: "npm、pip、Gradle、Cargo 的下载缓存，需要时会重新下载。",
            icon: "shippingbox",
            sources: [.item(".npm/_cacache"), .item(".cache/pip"), .item(".gradle/caches"), .item(".cargo/registry/cache")]),
        JunkRule(
            id: "mail", title: "邮件附件下载", detail: "在“邮件”里打开过的附件副本，邮件本身的附件不受影响。",
            icon: "envelope", sources: [.contents("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")]),
        JunkRule(
            id: "ios", title: "iOS 设备备份", detail: "iPhone / iPad 的本地备份。确认不再需要后再勾选。",
            icon: "iphone", sources: [.contents("Library/Application Support/MobileSync/Backup")],
            selectedByDefault: false),
        JunkRule(
            id: "ai", title: "本地 AI 模型", detail: "Ollama、LM Studio、Hugging Face 下载的模型，单个可达数 GB。确认项目不再使用后再勾选。",
            icon: "cpu", sources: [.item(".ollama/models"), .contents(".lmstudio/models"), .item(".cache/huggingface/hub")],
            selectedByDefault: false),
        JunkRule(
            id: "trash", title: "废纸篓", detail: "勾选后会永久删除废纸篓里的文件，无法恢复。",
            icon: "trash", sources: [.contents(".Trash")], selectedByDefault: false, permanent: true),
    ]
}

// MARK: - 扫描

struct JunkItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let size: Int64
    var selected: Bool
    var note: String? = nil
    var hint: String? = nil  // 显示在名字下面的一行说明
    var defaultSelected = true  // 扫描时的默认勾选，“恢复默认”用
    var id: URL { url }
}

struct JunkCategory: Identifiable {
    let rule: JunkRule
    var items: [JunkItem] = []
    var scanned = false
    var expanded = false

    var id: String { rule.id }
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedItems: [JunkItem] { items.filter(\.selected) }
}

enum JunkScanner {
    static let ignoredNames: Set<String> = [".DS_Store", ".localized"]

    /// 扫描时找到的候选项；owner 是所属应用的 bundle id 或名字，用来判断“运行中”。
    private struct Candidate {
        let url: URL
        let name: String
        var owner: String? = nil
    }

    /// 正在运行的应用的 bundle id 和名字（有的缓存目录用应用名命名）。
    static func runningAppKeys() -> Set<String> {
        let apps = NSWorkspace.shared.runningApplications
        return Set(apps.compactMap(\.bundleIdentifier) + apps.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName))
    }

    static func scan(_ rule: JunkRule, running: Set<String>, includeContainers: Bool = true) -> [JunkItem] {
        var candidates: [Candidate] = []
        for source in rule.sources {
            if !includeContainers {
                if case .containers = source { continue }
                switch source {
                case .appCache(_, _, let path), .allButLatest(_, _, let path):
                    if path.hasPrefix("Library/Containers/") || path.hasPrefix("Library/Group Containers/") { continue }
                default: break
                }
            }
            candidates += collect(source, rule: rule)
        }
        var seen = Set<String>()
        return candidates.compactMap { c -> JunkItem? in
            guard seen.insert(c.url.path).inserted else { return nil }
            let size = FS.size(of: c.url)
            guard size >= rule.minimumSize else { return nil }
            var item = JunkItem(url: c.url, name: c.name, size: size, selected: rule.selectedByDefault)
            if let owner = c.owner, running.contains(owner) {
                item.selected = false
                item.note = "运行中"
            }
            if let hint = browserEngineHint(for: c.url.lastPathComponent) {
                item.selected = false
                item.note = "浏览器内核"
                item.hint = hint
            }
            if c.url.lastPathComponent == "hub", c.url.deletingLastPathComponent().lastPathComponent == "huggingface" {
                item.hint = huggingFaceHint(c.url)
            }
            item.defaultSelected = item.selected
            return item
        }
        .sorted { $0.size > $1.size }
    }

    /// Hugging Face 缓存里的目录叫 models--作者--模型名，翻译成 作者/模型名 列出来。
    static func huggingFaceHint(_ hub: URL) -> String? {
        let models = FS.children(of: hub).map(\.lastPathComponent).filter { $0.hasPrefix("models--") }
            .map { $0.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/") }
            .sorted()
        guard !models.isEmpty else { return nil }
        return "包含：\(models.joined(separator: "、"))。删掉后，用到它们的工具下次运行时会重新下载。"
    }

    static func browserEngineHint(for name: String) -> String? {
        JunkRules.browserEngines[name].map {
            "\($0.tool) 下载的浏览器内核，不是普通缓存。删掉后用到它的工具会报错，要重新下载：\($0.reinstall)"
        }
    }

    private static func listed(_ dir: URL, rule: JunkRule) -> [URL] {
        FS.children(of: dir).filter {
            !rule.exclude.contains($0.lastPathComponent) && !ignoredNames.contains($0.lastPathComponent)
        }
    }

    private static func collect(_ source: JunkRule.Source, rule: JunkRule) -> [Candidate] {
        switch source {
        case .contents(let rel):
            return listed(FS.url(rel), rule: rule).map {
                Candidate(url: $0, name: displayName(for: $0, rule: rule), owner: $0.lastPathComponent)
            }
        case .item(let rel):
            let url = FS.url(rel)
            return FS.exists(url) ? [Candidate(url: url, name: FS.abbreviate(url.path))] : []
        case .containers(let sub):
            return FS.children(of: FS.url("Library/Containers")).flatMap { container -> [Candidate] in
                let id = containerBundleID(container)
                let app = appName(for: id) ?? id
                return listed(container.appendingPathComponent(sub), rule: rule).map {
                    Candidate(url: $0, name: "\(app)  ·  \($0.lastPathComponent)", owner: id)
                }
            }
        case .electronCaches:
            return electronCaches()
        case .brokenLaunchAgents:
            return FS.children(of: FS.url("Library/LaunchAgents"))
                .filter { $0.pathExtension == "plist" && LaunchAgents.isBroken($0) }
                .map { Candidate(url: $0, name: "启动代理  ·  \($0.lastPathComponent)") }
        case .appCache(let name, let owner, let path):
            return expand(path).map { url, matched in
                Candidate(url: url, name: matched.isEmpty ? name : "\(name)  ·  \(matched.joined(separator: "/"))", owner: owner)
            }
        case .allButLatest(let name, let owner, let path):
            let children = FS.children(of: FS.url(path)).filter { !$0.lastPathComponent.hasPrefix(".") }
            let latest = children.max { accessDate($0) < accessDate($1) }
            return children.filter { $0 != latest }.map {
                Candidate(url: $0, name: "\(name)  ·  \($0.lastPathComponent)", owner: owner)
            }
        case .brokenPreferences:
            return FS.children(of: FS.url("Library/Preferences"))
                .filter { $0.pathExtension == "plist" && isBrokenPlist($0) }
                .map { Candidate(url: $0, name: "偏好设置  ·  \($0.lastPathComponent)") }
        }
    }

    /// 展开相对主目录的路径，* 按 fnmatch 规则匹配目录名；返回存在的路径和每个 * 匹配到的名字。
    static func expand(_ path: String, base: URL = FS.home) -> [(URL, [String])] {
        var results: [(URL, [String])] = [(base, [])]
        for component in path.split(separator: "/").map(String.init) {
            results = results.flatMap { url, matched -> [(URL, [String])] in
                guard component.contains("*") else { return [(url.appendingPathComponent(component), matched)] }
                return FS.children(of: url)
                    .filter { FS.isDirectory($0) && fnmatch(component, $0.lastPathComponent, 0) == 0 }
                    .map { ($0, matched + [$0.lastPathComponent]) }
            }
        }
        return results.filter { FS.exists($0.0) }
    }

    /// 容器目录名通常就是 bundle id；以容器自己的元数据为准。
    private static func containerBundleID(_ container: URL) -> String {
        let meta = container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        return (NSDictionary(contentsOf: meta)?["MCMMetadataIdentifier"] as? String) ?? container.lastPathComponent
    }

    private static func appName(for bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent
    }

    /// Electron 应用把数据放在 Application Support/<产品名>（沙盒版在容器里），缓存在其中的 Cache 等目录。
    private static func electronCaches() -> [Candidate] {
        AppScanner.listApps()
            .filter { FS.exists($0.url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")) }
            .flatMap { app -> [Candidate] in
                let bases = [
                    FS.url("Library/Application Support"),
                    FS.url("Library/Containers/\(app.bundleID)/Data/Library/Application Support"),
                ]
                // 目录名是产品名，大小写不固定（比如 discord）
                let dirs = bases.flatMap(FS.children(of:)).filter { dir in
                    [app.name, app.bundleName].contains { $0.caseInsensitiveCompare(dir.lastPathComponent) == .orderedSame }
                }
                return dirs.flatMap { dir in
                    ["Cache", "Code Cache", "GPUCache"].map { dir.appendingPathComponent($0) }.filter(FS.exists)
                }
                .map { Candidate(url: $0, name: "\(app.name)  ·  \($0.lastPathComponent)", owner: app.bundleID) }
            }
    }

    private static func accessDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
    }

    /// 空文件或解析失败的 plist。读不了（没权限）不算损坏。
    static func isBrokenPlist(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        if data.isEmpty { return true }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil
    }

    /// 把 com.google.Chrome 这类目录名翻译成应用名，把 iOS 备份翻译成设备名。
    static func displayName(for url: URL, rule: JunkRule) -> String {
        let key = url.lastPathComponent
        if rule.id == "ios",
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")),
            let device = info["Device Name"] as? String
        {
            let date = (info["Last Backup Date"] as? Date).map { $0.formatted(date: .abbreviated, time: .omitted) }
            return date.map { "\(device)（\($0)）" } ?? device
        }
        if key.contains("."), let name = appName(for: key) {
            return "\(name)  ·  \(key)"
        }
        return key
    }
}

// MARK: - 状态

@MainActor
final class JunkModel: ObservableObject {
    enum Phase { case idle, scanning, ready, cleaning, done }

    @Published var categories: [JunkCategory] = JunkRules.all.map { JunkCategory(rule: $0) }
    @Published var phase: Phase = .idle
    @Published var scanningTitle = ""
    @Published var progress: Double = 0
    @Published var result: CleanResult?

    var busy: Bool { phase == .scanning || phase == .cleaning }
    var total: Int64 { categories.reduce(0) { $0 + $1.total } }
    var selected: [(item: JunkItem, permanent: Bool)] {
        categories.flatMap { c in c.selectedItems.map { ($0, c.rule.permanent) } }
    }
    var selectedSize: Int64 { selected.reduce(0) { $0 + $1.item.size } }
    var hasItems: Bool { categories.contains { !$0.items.isEmpty } }

    func scan() { Task { await runScan() } }

    func runScan() async {
        guard !busy else { return }
        result = nil
        progress = 0
        phase = .scanning
        categories = JunkRules.all.map { JunkCategory(rule: $0) }
        let running = JunkScanner.runningAppKeys()
        for i in categories.indices {
            let rule = categories[i].rule
            scanningTitle = rule.title
            let items = await Task.detached(priority: .userInitiated) {
                JunkScanner.scan(rule, running: running)
            }.value
            categories[i].items = items
            categories[i].scanned = true
            progress = Double(i + 1) / Double(categories.count)
        }
        scanningTitle = ""
        phase = .ready
    }

    func clean() { Task { await runClean() } }

    func runClean() async {
        let targets = selected.map { Cleaner.Target(url: $0.item.url, size: $0.item.size, permanent: $0.permanent) }
        guard !targets.isEmpty, !busy else { return }
        phase = .cleaning
        result = await Task.detached(priority: .userInitiated) { Cleaner.perform(targets) }.value
        if let result { StatsStore.shared.record(.junk, result) }
        phase = .done
    }

    func reset() {
        guard !busy else { return }
        result = nil
        categories = JunkRules.all.map { JunkCategory(rule: $0) }
        phase = .idle
    }

    /// 全选除“废纸篓”以外的所有项目；废纸篓是永久删除，必须单独勾选。
    func selectAll() {
        for c in categories.indices where !categories[c].rule.permanent {
            for i in categories[c].items.indices { categories[c].items[i].selected = true }
        }
    }

    func restoreDefaults() {
        for c in categories.indices {
            for i in categories[c].items.indices {
                categories[c].items[i].selected = categories[c].items[i].defaultSelected
            }
        }
    }

    var confirmMessage: String {
        let toTrash = selected.filter { !$0.permanent }.map(\.item)
        let toDelete = selected.filter(\.permanent).map(\.item)
        var lines: [String] = []
        if !toTrash.isEmpty {
            lines.append("将把 \(toTrash.count) 项（\(FS.format(toTrash.reduce(0) { $0 + $1.size }))）移到废纸篓，需要时可以从废纸篓恢复。")
        }
        if !toDelete.isEmpty {
            lines.append("废纸篓中的 \(toDelete.count) 项（\(FS.format(toDelete.reduce(0) { $0 + $1.size }))）将被永久删除，无法恢复。")
        }
        let running = toTrash.filter { $0.note == "运行中" }.count
        if running > 0 {
            lines.append("其中 \(running) 项属于正在运行的应用，清理后这些应用可能出错，最好先把它们退出。")
        }
        let engines = toTrash.filter { $0.note == "浏览器内核" }.map(\.name)
        if !engines.isEmpty {
            lines.append("包含浏览器内核（\(engines.joined(separator: "、"))），删掉后用到它的工具需要重新下载。")
        }
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - 界面

struct CleanupView: View {
    @ObservedObject var model: JunkModel
    @ObservedObject var disk: DiskModel
    @State private var showDetails = false
    @State private var confirming = false
    @State private var showFailures = false
    private let module = Module.cleanup

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                VStack(spacing: 0) {
                    StageTopBar(title: module.title)
                    ModuleIntro(module: module) { model.scan() }
                }
            case .scanning:
                VStack(spacing: 0) {
                    StageTopBar(title: module.title)
                    ScanningStage(
                        module: module, title: "正在扫描…",
                        detail: model.scanningTitle.isEmpty ? "准备中" : "正在查看：\(model.scanningTitle)",
                        progress: model.progress, stop: nil)
                }
            case .ready where showDetails:
                details
            case .ready:
                summary
            case .cleaning:
                VStack(spacing: 0) {
                    StageTopBar(title: module.title)
                    ScanningStage(module: module, title: "正在清理…", detail: "把选中的项目移到废纸篓", stop: nil)
                }
            case .done:
                done
            }
        }
        .alert("确认清理", isPresented: $confirming) {
            Button("清理", role: .destructive) {
                showDetails = false
                model.clean()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.confirmMessage)
        }
        .onChange(of: model.phase) { _, _ in disk.refresh() }
    }

    private var summary: some View {
        VStack(spacing: 0) {
            StageTopBar(leadingTitle: "重新开始", leadingAction: { model.reset() }, title: module.title)
            ResultStage(
                module: module,
                headline: model.total > 0 ? "找到 \(FS.format(model.total)) 垃圾" : "很干净，没找到垃圾",
                subline: model.total > 0
                    ? "已勾选 \(FS.format(model.selectedSize))：删了会自动重新生成，可以放心一键清理。其余的有代价，要你自己决定。"
                    : "过段时间再来扫一次吧。",
                primaryTitle: "清理", primaryDisabled: model.selected.isEmpty, primaryAction: { confirming = true }
            ) {
                let top = model.categories.filter { $0.total > 0 }.sorted { $0.total > $1.total }.prefix(4)
                if !top.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(Array(top)) { cat in
                            SummaryRow(icon: cat.rule.icon, title: cat.rule.title, value: FS.format(cat.total), accent: module.accent)
                        }
                    }
                    .padding(14)
                    .glass(cornerRadius: 16)
                    PillButton(title: "查看详情", icon: "list.bullet") { showDetails = true }
                }
            }
        }
    }

    private var details: some View {
        DetailFrame(title: "清理详情", back: { showDetails = false }) {
            List {
                ForEach($model.categories) { $cat in
                    if !cat.items.isEmpty {
                        DisclosureGroup(isExpanded: $cat.expanded) {
                            ForEach($cat.items) { $item in
                                ItemRow(item: $item).listRowBackground(Color.clear)
                            }
                        } label: {
                            CategoryRow(cat: $cat, scanning: false, accent: module.accent)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } footer: {
            Text("已选 \(model.selected.count) 项，共 \(FS.format(model.selectedSize))")
                .foregroundStyle(.white.opacity(0.75))
                .monospacedDigit()
            Spacer()
            PillButton(title: "全选") { model.selectAll() }
                .help("勾选除“废纸篓”以外的所有项目。废纸篓会永久删除，需要单独勾选。")
            PillButton(title: "恢复默认") { model.restoreDefaults() }
                .help("回到扫描时的默认勾选：正在运行的应用、浏览器内核、聊天缓存、AI 模型、废纸篓不勾。")
            ActionCapsule(title: "一键清理", accent: module.accent, disabled: model.selected.isEmpty) { confirming = true }
        }
    }

    private var done: some View {
        VStack(spacing: 0) {
            StageTopBar(title: module.title)
            ResultStage(
                module: module, symbol: "checkmark.seal.fill", headline: "清理完成",
                subline: model.result?.summary ?? "",
                primaryTitle: "完成", primaryAction: { model.reset() }
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    if let r = model.result, r.trashedCount > 0 {
                        Text("东西都还在废纸篓里，随时能放回；清空废纸篓后才真正腾出空间。")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    HStack(spacing: 10) {
                        PillButton(title: "打开废纸篓", icon: "trash") { NSWorkspace.shared.open(FS.url(".Trash")) }
                        if let r = model.result, !r.failures.isEmpty {
                            PillButton(title: "\(r.failures.count) 项没清掉", icon: "exclamationmark.triangle") { showFailures = true }
                                .popover(isPresented: $showFailures) { FailureList(failures: r.failures) }
                        }
                    }
                }
            }
        }
    }
}

struct FailureList: View {
    let failures: [CleanFailure]

    var body: some View {
        List(failures) { f in
            VStack(alignment: .leading, spacing: 2) {
                Text(FS.abbreviate(f.path)).lineLimit(1).truncationMode(.middle)
                Text(f.reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 460, height: 260)
    }
}

struct CategoryRow: View {
    @Binding var cat: JunkCategory
    var scanning: Bool
    var accent: Color = .accentColor

    var body: some View {
        HStack(spacing: 12) {
            // 空分类用一个不可点的空框；Toggle(sources:) 在没有元素时会画成灰色的勾，看起来像“已选但锁住”
            Group {
                if cat.items.isEmpty {
                    Toggle(isOn: .constant(false)) { EmptyView() }.disabled(true)
                } else {
                    Toggle(sources: $cat.items, isOn: \.selected) { EmptyView() }
                }
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            Image(systemName: cat.rule.icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(cat.rule.permanent ? Color.red : accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(cat.rule.title).font(.headline)
                Text(cat.rule.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if scanning {
                ProgressView().controlSize(.small)
            } else {
                Text(cat.scanned ? FS.format(cat.total) : "—")
                    .monospacedDigit()
                    .foregroundStyle(cat.total > 0 ? .primary : .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ItemRow: View {
    @Binding var item: JunkItem

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $item.selected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if let hint = item.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            if let note = item.note {
                Text(note)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(FS.format(item.size)).monospacedDigit().foregroundStyle(.secondary)
            Button {
                FS.reveal([item.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
        }
        .help(FS.abbreviate(item.url.path))
    }
}
