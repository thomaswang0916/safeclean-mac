import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        // 放心清理 --put-back <废纸篓里的路径> <原位置>：把东西从废纸篓放回去（借用本应用的完全磁盘访问权限）
        if let i = CommandLine.arguments.firstIndex(of: "--put-back"), CommandLine.arguments.count > i + 2 {
            exit(PutBack.run(from: CommandLine.arguments[i + 1], to: CommandLine.arguments[i + 2]))
        }
        // 后台定时记录（由启动代理调用）：记一次空间快照，顺便复查之前清掉的东西长回来没有
        if CommandLine.arguments.contains("--snapshot") {
            SpaceRecorder.record()
            Regrowth.runChecks()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--test-clutter"), CommandLine.arguments.count > i + 1 {
            SelfTest.clutter(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        if CommandLine.arguments.contains("--test-detective") {
            SelfTest.detective()
            return
        }
        if CommandLine.arguments.contains("--test-updates") {
            SelfTest.updates()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let root = CommandLine.arguments.dropFirst(i + 1).first.map { URL(fileURLWithPath: $0) }
            SelfTest.run(largeFileRoot: root)
            return
        }
        SafeCleanApp.main()
    }
}

struct SafeCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(L("放心清理", "SafeClean")) {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands { CommandGroup(replacing: .newItem) {} }
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(DebugFlags.readOnly ? .accessory : .regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 截图 / 录演示时不抢焦点，避免接住用户在别的应用里的点击或回车
        if !DebugFlags.readOnly { NSApp.activate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - 从废纸篓放回

enum PutBack {
    /// 只允许把 ~/.Trash 里的东西挪出来，而且目标位置不能已经有东西。
    static func run(from source: String, to destination: String) -> Int32 {
        let trash = FS.url(".Trash").standardizedFileURL.path + "/"
        let src = URL(fileURLWithPath: source).standardizedFileURL
        let dst = URL(fileURLWithPath: destination).standardizedFileURL
        guard src.path.hasPrefix(trash) else {
            print("拒绝：只能从废纸篓放回（\(src.path) 不在 ~/.Trash 里）")
            return 2
        }
        guard FS.exists(src) else {
            print("废纸篓里没有：\(src.path)")
            return 1
        }
        guard !FS.exists(dst) else {
            print("拒绝：原位置已经有东西了：\(dst.path)")
            return 2
        }
        do {
            try FS.fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FS.fm.moveItem(at: src, to: dst)
            print("已放回：\(dst.path)")
            return 0
        } catch {
            print("放回失败：\(error.localizedDescription)")
            return 1
        }
    }
}

// MARK: - 自检（只读，不删除任何东西）

enum SelfTest {
    static func detective() {
        let snaps = SpaceRecorder.loadSnapshots()
        print("快照数:", snaps.count, "最后一次位置数:", snaps.last?.locations.count ?? 0, "进程数:", snaps.last?.processes.count ?? 0)
        if let change = SpaceComparer.compare(snaps, since: .distantPast) {
            print("可用空间变化（正数=少了）:", FS.format(change.freeLost))
            change.growth.prefix(5).forEach { print("  变大:", $0.title, "+\(FS.format($0.delta))") }
            change.writers.prefix(5).forEach { print("  写入:", $0.title, FS.format($0.delta)) }
        }
        for item in SystemDataInspector.inspect() {
            print("系统数据:", item.title, item.size.map(FS.format) ?? "—")
        }
        if let path = CommandLine.arguments.drop(while: { $0 != "--fake-regrowth" }).dropFirst().first {
            // 伪造一条“两天前清理过”的记录，验证复查和清理模块的默认勾选
            var all = Regrowth.load()
            all.append(CleanedEntry(path: path, size: 100_000_000, date: Date().addingTimeInterval(-2 * 86400)))
            DetectiveStore.save(all, to: DetectiveStore.regrowthURL)
            let checked = Regrowth.runChecks().first { $0.path == path }
            print("复查:", checked.map { "清掉 \(FS.format($0.size))，一天后 \(FS.format($0.after1d ?? 0))" } ?? "无")
            let items = JunkScanner.scan(JunkRules.all[0], running: [], includeContainers: false)
            if let item = items.first(where: { $0.url.path == path }) {
                print("清理模块:", item.selected ? "[x]" : "[ ]", item.name, item.note ?? "", item.hint ?? "")
            }
        }
    }

    static func clutter(_ root: URL) {
        let flag = CancelFlag()
        let entries = ClutterScanner.walk(root: root, minSize: 1, cancel: flag) { _ in }
        print("文件:", entries.count)
        for g in ClutterScanner.duplicates(entries, cancel: flag) {
            print("重复组:", g.files.map { "\($0.selected ? "[x]" : "[ ]") \($0.name)\($0.note.map { "（\($0)）" } ?? "")" })
            if CommandLine.arguments.contains("--paths") { g.files.forEach { print("    ", $0.size, $0.url.path) } }
        }
        for g in ClutterScanner.similarImages(entries, cancel: flag, progress: { _, _ in }) {
            print("相似组:", g.files.map { "\($0.name)\($0.note.map { "（\($0)）" } ?? "")" })
        }
        let tree = SpaceScanner.scan(root: root, includeHidden: true, cancel: flag) { _, _ in }
        print("空间透镜:", tree.name, FS.format(tree.size), tree.children.map { "\($0.name) \(FS.format($0.size))" })
        let rects = Treemap.layout([6, 6, 4, 3, 2, 2, 1], in: CGRect(x: 0, y: 0, width: 600, height: 400))
        let area = rects.reduce(0) { $0 + $1.width * $1.height }
        print("方块图面积合计:", Int(area), "（应为 240000）")
    }

    static func updates() {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let apps = AppScanner.listApps()
            let candidates = apps.filter(UpdateChecker.supportsCheck)
            print("可检查更新的应用:", candidates.count, "/", apps.count)
            for app in candidates {
                if let u = await UpdateChecker.check(app) {
                    print("  有更新:", app.name, u.installed, "→", u.latest, u.source == .appStore ? "App Store" : "Sparkle")
                }
            }
            print("检查完毕")
            sem.signal()
        }
        sem.wait()
    }

    static func run(largeFileRoot: URL?) {
        print("完全磁盘访问权限:", Permissions.hasFullDiskAccess())
        for (path, ok) in Permissions.probeResults() { print("   ", path, ok.map { $0 ? "可读" : "被拒" } ?? "不存在") }
        let running = JunkScanner.runningAppKeys()
        var total: Int64 = 0
        for rule in JunkRules.all {
            // 读其他应用的沙盒容器会弹“访问其他应用的数据”授权框，自检默认跳过
            let items = JunkScanner.scan(rule, running: running, includeContainers: CommandLine.arguments.contains("--containers"))
            let size = items.reduce(0) { $0 + $1.size }
            total += size
            let top = items.prefix(3).map { "\($0.name) \(FS.format($0.size))" }.joined(separator: " | ")
            let kept = items.filter { $0.note != nil }.map { "\($0.name)（\($0.note!)）" }
            print("[\(rule.title)] \(items.count) 项, \(FS.format(size))  \(top)" + (kept.isEmpty ? "" : "  默认不勾: \(kept)"))
            if CommandLine.arguments.contains("--detail") {
                items.forEach { print("      ", $0.selected ? "[x]" : "[ ]", $0.name, FS.format($0.size), $0.note ?? "", $0.hint ?? "") }
            }
        }
        print("垃圾合计:", FS.format(total))

        let apps = AppScanner.listApps()
        print("第三方应用:", apps.count, "个")
        if let app = apps.first {
            let left = AppScanner.leftovers(for: app)
            print("\(app.name) (\(app.bundleID)) 残留 \(left.count) 项:")
            print("    App Groups:", AppScanner.appGroups(of: app.url), " 组件:", AppScanner.bundleIDs(in: app).count)
            left.forEach { print("   ", $0.selected ? "[x]" : "[ ]", $0.name, FS.format($0.size), $0.note ?? "") }
        }

        if let root = largeFileRoot {
            let found = LargeFileScanner.scan(root: root, threshold: 50_000_000, cancel: CancelFlag()) { _, _ in }
            print("大文件(\(root.path), >50MB):", found.map { "\($0.name) \(FS.format($0.size))" })
            let globbed = JunkScanner.expand("tg/*/account-*/postbox/media", base: root)
            print("通配展开:", globbed.map { "\(FS.abbreviate($0.0.path)) \($0.1)" })
        }
        let disk = try? FS.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        print("可用空间:", FS.format(disk?.volumeAvailableCapacityForImportantUsage ?? 0))
    }
}

// MARK: - 调试截图（只在 debug 构建里存在）

#if DEBUG
    extension JunkModel {
        /// 不扫描磁盘，填几条示例数据，用来检查列表的样子。
        func loadSample() {
            var cat = JunkCategory(rule: JunkRules.all[0])
            let caches = URL(fileURLWithPath: "/private/tmp/SafeClean Sample/Library/Caches")
            cat.items = [
                JunkItem(
                    url: caches.appendingPathComponent("ms-playwright"), name: "ms-playwright", size: 584_100_000, selected: false,
                    note: L("浏览器内核", "Browser engine"), hint: JunkScanner.browserEngineHint(for: "ms-playwright")),
                JunkItem(url: caches.appendingPathComponent("GeoServices"), name: "GeoServices", size: 130_000_000, selected: true),
                JunkItem(
                    url: caches.appendingPathComponent("com.anthropic.claudefordesktop"), name: "Claude  ·  com.anthropic.claudefordesktop",
                    size: 2_200_000, selected: false, note: L("运行中", "Running")),
            ]
            for i in cat.items.indices { cat.items[i].defaultSelected = cat.items[i].selected }
            cat.scanned = true
            cat.expanded = true
            categories[0] = cat
            var logs = JunkCategory(rule: JunkRules.all[2])
            logs.items = [JunkItem(url: URL(fileURLWithPath: "/private/tmp/SafeClean Sample/Library/Logs/CreativeCloud"), name: "CreativeCloud", size: 22_300_000, selected: true)]
            logs.scanned = true
            categories[2] = logs
            for c in categories.indices where !categories[c].scanned { categories[c].scanned = true }
            phase = .ready
        }
    }

    /// SAFECLEAN_SNAPSHOT=out.png SAFECLEAN_MODULE=<模块> [SAFECLEAN_STAGE=<阶段>] 启动后切到对应页面并把窗口画成图片。
    enum DebugSnapshot {
        static var env: [String: String] { ProcessInfo.processInfo.environment }

        @MainActor static func run(state: AppState) async {
            if let demo = env["SAFECLEAN_DEMO"] {
                let root = URL(fileURLWithPath: env["SAFECLEAN_ROOT"] ?? FS.home.path)
                await DemoDirector.run(state: state, output: URL(fileURLWithPath: demo), lensRoot: root)
                return
            }
            guard let path = env["SAFECLEAN_SNAPSHOT"] else { return }
            state.module = Module(rawValue: env["SAFECLEAN_MODULE"] ?? "") ?? .smartCare
            let stage = env["SAFECLEAN_STAGE"] ?? "intro"
            await DebugStages.prepare(state: state, stage: stage)
            try? await Task.sleep(for: .seconds(Double(env["SAFECLEAN_WAIT"] ?? "") ?? 2.5))
            capture(to: path)
            NSApp.terminate(nil)
        }

        @MainActor static func capture(to path: String) {
            guard let window = NSApp.windows.first(where: \.isVisible),
                let view = window.contentView?.superview ?? window.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
#endif
