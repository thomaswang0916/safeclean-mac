import AppKit
import Darwin
import SwiftUI

// MARK: - 命令行

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// 用 macOS 自己的管理员密码框执行命令；密码由系统处理，本应用拿不到。
    static func runAsAdmin(_ command: String, prompt: String) -> (ok: Bool, output: String) {
        guard !DebugFlags.readOnly else { return (true, "") }
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let script = "do shell script \(quote(command)) with prompt \(quote(prompt)) with administrator privileges"
        let r = run("/usr/bin/osascript", ["-e", script])
        return (r.status == 0, r.output)
    }
}

// MARK: - 维护任务

struct MaintenanceTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let needsAdmin: Bool
    let command: String
    var selected: Bool

    static let all: [MaintenanceTask] = [
        MaintenanceTask(
            id: "ram", title: L("释放内存", "Free Up RAM"), detail: L("把系统缓存在内存里、暂时用不到的数据清出去，给正在用的应用腾地方。", "Clears data macOS has cached in memory but isn't using, making room for the apps you're running."),
            icon: "memorychip", needsAdmin: true, command: "/usr/sbin/purge", selected: true),
        MaintenanceTask(
            id: "dns", title: L("刷新 DNS 缓存", "Flush DNS Cache"), detail: L("网页打不开、域名解析到旧地址时有用。", "Helps when websites won't load or a domain still points to an old address."),
            icon: "network", needsAdmin: true, command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder",
            selected: true),
        MaintenanceTask(
            id: "quicklook", title: L("重置快速查看缓存", "Reset Quick Look Cache"), detail: L("空格预览显示旧内容或缩略图不对时有用。", "Helps when Quick Look shows outdated previews or wrong thumbnails."),
            icon: "eye", needsAdmin: false, command: "/usr/bin/qlmanage -r cache", selected: true),
        MaintenanceTask(
            id: "launchservices", title: L("重建“打开方式”菜单", "Rebuild the \"Open With\" Menu"),
            detail: L("右键“打开方式”里出现重复或已删除的应用时用。重建需要一两分钟，期间图标可能短暂显示不正常。", "Use this when \"Open With\" lists duplicate or deleted apps. It takes a minute or two, and icons may look wrong briefly."), icon: "list.bullet.rectangle",
            needsAdmin: false,
            command:
                "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user",
            selected: false),
        MaintenanceTask(
            id: "spotlight", title: L("重建 Spotlight 索引", "Reindex Spotlight"), detail: L("搜索找不到文件时用。后台会重新索引整个磁盘，可能要几十分钟、风扇会转。", "Use this when search can't find your files. The whole disk is reindexed in the background — this can take a while and spin up the fans."),
            icon: "magnifyingglass", needsAdmin: true, command: "/usr/bin/mdutil -E /", selected: false),
    ]
}

// MARK: - 后台项

struct BackgroundItem: Identifiable {
    enum Scope { case user, systemAgent, systemDaemon }

    let plist: URL
    let label: String
    let program: String
    let owner: String
    let appURL: URL?
    let scope: Scope
    var loaded: Bool
    var disabled: Bool

    var id: URL { plist }
    var editable: Bool { scope == .user }
}

// MARK: - 高耗能应用

struct HeavyApp: Identifiable {
    let pid: pid_t
    let name: String
    let url: URL?
    let memory: Int64
    let cpu: Double
    var id: pid_t { pid }
}

enum SystemInfo {
    static func memoryUsage() -> (used: Int64, total: Int64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = Int64(vm_kernel_page_size)
        let used = (Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        return (used, total)
    }

    /// 每个 pid 的内存（RSS）和 CPU 占用
    static func processUsage() -> [pid_t: (memory: Int64, cpu: Double)] {
        let output = Shell.run("/bin/ps", ["-axo", "pid=,rss=,%cpu="]).output
        var usage: [pid_t: (Int64, Double)] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = pid_t(parts[0]), let rss = Int64(parts[1]), let cpu = Double(parts[2]) else { continue }
            usage[pid] = (rss * 1024, cpu)
        }
        return usage
    }

    static func heavyApps() -> [HeavyApp] {
        let usage = processUsage()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app -> HeavyApp? in
                guard let u = usage[app.processIdentifier] else { return nil }
                return HeavyApp(
                    pid: app.processIdentifier, name: app.localizedName ?? L("未知应用", "Unknown app"), url: app.bundleURL, memory: u.memory, cpu: u.cpu)
            }
            .sorted { $0.memory > $1.memory }
    }

    static func backgroundItems() -> [BackgroundItem] {
        let uid = getuid()
        let disabledOutput = Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]).output
        let disabledLabels = Set(
            disabledOutput.split(separator: "\n").compactMap { line -> String? in
                guard line.contains("=> disabled") || line.contains("=> true") else { return nil }
                return line.split(separator: "\"").dropFirst().first.map(String.init)
            })
        let sources: [(URL, BackgroundItem.Scope)] = [
            (FS.url("Library/LaunchAgents"), .user),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon),
        ]
        var items: [BackgroundItem] = []
        for (dir, scope) in sources {
            for plist in FS.children(of: dir) where plist.pathExtension == "plist" {
                guard let d = NSDictionary(contentsOf: plist) as? [String: Any] else { continue }
                let label = d["Label"] as? String ?? plist.deletingPathExtension().lastPathComponent
                if label.hasPrefix("com.apple.") { continue }
                let program = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first ?? ""
                var appURL: URL?
                if let range = program.range(of: ".app/") {
                    appURL = URL(fileURLWithPath: String(program[..<range.lowerBound]) + ".app")
                }
                let owner = appURL?.deletingPathExtension().lastPathComponent ?? label
                let loaded = scope == .user ? Shell.run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"]).status == 0 : true
                items.append(
                    BackgroundItem(
                        plist: plist, label: label, program: program, owner: owner, appURL: appURL, scope: scope, loaded: loaded,
                        disabled: disabledLabels.contains(label) || (d["Disabled"] as? Bool ?? false)))
            }
        }
        return items.sorted { $0.owner.localizedStandardCompare($1.owner) == .orderedAscending }
    }
}

// MARK: - 状态

@MainActor
final class PerformanceModel: ObservableObject {
    enum Screen: Equatable { case intro, scanning, overview, maintenance, background, heavy, running, done }

    @Published var screen: Screen = .intro
    @Published var tasks = MaintenanceTask.all
    @Published var items: [BackgroundItem] = []
    @Published var heavy: [HeavyApp] = []
    @Published var memoryUsed: Int64 = 0
    @Published var memoryTotal: Int64 = 0
    @Published var runLog: [(String, Bool)] = []
    @Published var message: String?

    static let heavyThreshold: Int64 = 1_000_000_000

    var heavyCount: Int { heavy.filter { $0.memory >= Self.heavyThreshold }.count }
    var activeBackgroundCount: Int { items.filter { !$0.disabled }.count }
    var recommendationCount: Int { tasks.filter(\.selected).count + heavyCount }

    func scan() { Task { await analyze(showProgress: true) } }

    func analyze(showProgress: Bool = false) async {
        if showProgress { screen = .scanning }
        let (items, heavy, memory) = await Task.detached(priority: .userInitiated) {
            (SystemInfo.backgroundItems(), SystemInfo.heavyApps(), SystemInfo.memoryUsage())
        }.value
        self.items = items
        self.heavy = heavy
        memoryUsed = memory.used
        memoryTotal = memory.total
        if showProgress { screen = .overview }
    }

    func refreshHeavy() {
        Task {
            let (heavy, memory) = await Task.detached { (SystemInfo.heavyApps(), SystemInfo.memoryUsage()) }.value
            self.heavy = heavy
            memoryUsed = memory.used
            memoryTotal = memory.total
        }
    }

    func runSelectedTasks() {
        let chosen = tasks.filter(\.selected)
        guard !chosen.isEmpty else { return }
        screen = .running
        Task {
            var log: [(String, Bool)] = []
            let admin = chosen.filter(\.needsAdmin)
            if !admin.isEmpty {
                let command = admin.map(\.command).joined(separator: "; ")
                let titles = admin.map(\.title).joined(separator: L("、", ", "))
                let r = await Task.detached {
                    Shell.runAsAdmin(command, prompt: L("放心清理 要运行维护任务：\(titles)", "SafeClean wants to run maintenance tasks: \(titles)"))
                }.value
                log += admin.map { ($0.title, r.ok) }
            }
            for task in chosen where !task.needsAdmin {
                let command = task.command
                let r = await Task.detached { Shell.run("/bin/sh", ["-c", command]) }.value
                log.append((task.title, r.status == 0))
            }
            runLog = log
            StatsStore.shared.record(.maintenance, bytes: 0, items: log.filter(\.1).count)
            await analyze()
            screen = .done
        }
    }

    func setEnabled(_ item: BackgroundItem, _ enabled: Bool) {
        guard item.editable, !DebugFlags.readOnly else { return }
        let target = "gui/\(getuid())"
        Task {
            await Task.detached {
                if enabled {
                    Shell.run("/bin/launchctl", ["enable", "\(target)/\(item.label)"])
                    Shell.run("/bin/launchctl", ["bootstrap", target, item.plist.path])
                } else {
                    Shell.run("/bin/launchctl", ["bootout", target, item.plist.path])
                    Shell.run("/bin/launchctl", ["disable", "\(target)/\(item.label)"])
                }
            }.value
            items = await Task.detached { SystemInfo.backgroundItems() }.value
        }
    }

    func quit(_ app: HeavyApp) {
        guard !DebugFlags.readOnly else { return }
        NSRunningApplication(processIdentifier: app.pid)?.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            refreshHeavy()
        }
    }
}

// MARK: - 界面

struct PerformanceView: View {
    @ObservedObject var model: PerformanceModel
    private let module = Module.performance

    var body: some View {
        switch model.screen {
        case .intro:
            VStack(spacing: 0) {
                StageTopBar(title: module.title)
                ModuleIntro(module: module) { model.scan() }
            }
        case .scanning:
            VStack(spacing: 0) {
                StageTopBar(title: module.title)
                ScanningStage(module: module, title: L("正在分析…", "Analyzing…"), detail: L("查看后台项、内存和正在运行的应用", "Checking background items, memory and running apps"), stop: nil)
            }
        case .overview:
            overview
        case .maintenance:
            maintenance
        case .background:
            background
        case .heavy:
            heavyApps
        case .running:
            VStack(spacing: 0) {
                StageTopBar(title: module.title)
                ScanningStage(module: module, title: L("正在运行维护任务…", "Running maintenance tasks…"), detail: L("需要管理员权限的任务会弹出系统密码框", "Tasks that need admin rights will show the macOS password prompt"), stop: nil)
            }
        case .done:
            VStack(spacing: 0) {
                StageTopBar(title: module.title)
                ResultStage(
                    module: module, symbol: "checkmark.seal.fill", headline: L("维护完成", "Maintenance Complete"),
                    subline: L("内存已用 \(FS.format(model.memoryUsed)) / \(FS.format(model.memoryTotal))", "Memory used: \(FS.format(model.memoryUsed)) / \(FS.format(model.memoryTotal))"),
                    primaryTitle: L("完成", "Done"), primaryAction: { model.screen = .overview }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.runLog, id: \.0) { title, ok in
                            if ok { DoneChip(text: title) } else { DoneChip(text: L("\(title)：没有完成（可能取消了密码框）", "\(title): not completed (the password prompt may have been cancelled)"), color: Color(hex: 0xFFC46B)) }
                        }
                    }
                }
            }
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            StageTopBar(leadingTitle: L("重新开始", "Start Over"), leadingAction: { model.screen = .intro }, title: module.title)
            StageLayout(module: module, symbol: module.heroSymbol) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("\(model.recommendationCount) 项建议", "\(model.recommendationCount) Recommendations")).font(.system(size: 40, weight: .bold))
                    Text(L("内存已用 \(FS.format(model.memoryUsed)) / \(FS.format(model.memoryTotal))", "Memory used: \(FS.format(model.memoryUsed)) / \(FS.format(model.memoryTotal))"))
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.78))
                        .monospacedDigit()
                    ActionTile(
                        icon: "wrench.and.screwdriver.fill", title: L("维护任务", "Maintenance Tasks"),
                        value: L("已选 \(model.tasks.filter(\.selected).count) 项，可随时运行", "\(model.tasks.filter(\.selected).count) selected, ready to run"), accent: module.accent
                    ) { model.screen = .maintenance }
                    ActionTile(
                        icon: "switch.2", title: L("后台启动项", "Background Items"),
                        value: L("\(model.items.count) 个第三方，\(model.activeBackgroundCount) 个在启用", "\(model.items.count) third-party, \(model.activeBackgroundCount) enabled"), accent: module.accent
                    ) { model.screen = .background }
                    ActionTile(
                        icon: "gauge.with.dots.needle.67percent", title: L("高耗能应用", "Heavy Consumers"),
                        value: model.heavyCount > 0 ? L("\(model.heavyCount) 个占用超过 1 GB 内存", "\(model.heavyCount) using over 1 GB of memory") : L("没有特别占内存的应用", "No app is using an unusual amount of memory"),
                        accent: module.accent, highlight: model.heavyCount > 0
                    ) { model.screen = .heavy }
                }
            } bottom: {
                OrbButton(title: L("运行", "Run"), accent: module.accent, disabled: !model.tasks.contains(where: \.selected)) {
                    model.runSelectedTasks()
                }
            }
        }
    }

    private var maintenance: some View {
        DetailFrame(title: L("维护任务", "Maintenance Tasks"), back: { model.screen = .overview }) {
            List {
                ForEach($model.tasks) { $task in
                    HStack(spacing: 12) {
                        Toggle(isOn: $task.selected) { EmptyView() }.toggleStyle(.checkbox).labelsHidden()
                        Image(systemName: task.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(module.accent.opacity(0.45)))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(task.title).font(.system(size: 15, weight: .semibold))
                                if task.needsAdmin {
                                    Text(L("需要密码", "Password"))
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.white.opacity(0.14)))
                                }
                            }
                            Text(task.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } footer: {
            Text(L("需要密码的任务会弹出 macOS 自己的密码框，本应用拿不到你的密码。", "Tasks marked Password use the macOS password prompt — SafeClean never sees your password."))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
            ActionCapsule(title: L("运行所选", "Run Selected"), accent: module.accent, disabled: !model.tasks.contains(where: \.selected)) {
                model.runSelectedTasks()
            }
        }
    }

    private var background: some View {
        DetailFrame(title: L("后台启动项", "Background Items"), back: { model.screen = .overview }) {
            List {
                if model.items.isEmpty {
                    Text(L("没有第三方后台启动项", "No third-party background items")).foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
                ForEach(model.items) { item in
                    HStack(spacing: 12) {
                        Group {
                            if let app = item.appURL, FS.exists(app) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable()
                            } else {
                                Image(systemName: "gearshape.2.fill").resizable().scaledToFit().padding(5)
                            }
                        }
                        .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.owner).font(.system(size: 14, weight: .semibold))
                            Text(item.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                        Spacer()
                        Text(scopeText(item))
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                        if item.editable {
                            Toggle("", isOn: Binding(get: { !item.disabled }, set: { model.setEnabled(item, $0) }))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .help(item.disabled ? L("已停用，打开后重新启用", "Disabled. Turn on to re-enable.") : L("关闭后停止运行，登录时也不会再启动", "Turning it off stops it now and at future logins"))
                        } else {
                            Button { FS.reveal([item.plist]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless)
                                .help(L("系统级项目，改动需要管理员权限，可以在 Finder 里查看", "System-wide item. Changing it needs admin rights; you can view it in Finder."))
                        }
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } footer: {
            Text(L("只有你自己的启动代理可以在这里开关；系统级的需要管理员权限。", "Only your own launch agents can be toggled here; system-wide ones need admin rights."))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
            PillButton(title: L("打开登录项设置", "Open Login Items Settings"), icon: "gearshape") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            }
        }
    }

    private func scopeText(_ item: BackgroundItem) -> String {
        switch item.scope {
        case .user: item.disabled ? L("已停用", "Disabled") : (item.loaded ? L("运行中", "Running") : L("已启用", "Enabled"))
        case .systemAgent: L("系统级", "System")
        case .systemDaemon: L("系统服务", "System service")
        }
    }

    private var heavyApps: some View {
        DetailFrame(title: L("高耗能应用", "Heavy Consumers"), back: { model.screen = .overview }) {
            List(model.heavy) { app in
                HStack(spacing: 12) {
                    if let url = app.url {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 30, height: 30)
                    }
                    Text(app.name).font(.system(size: 14, weight: .semibold))
                    if app.memory >= PerformanceModel.heavyThreshold {
                        Text(L("占用较多", "Heavy"))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(hex: 0xFF9A4D).opacity(0.35)))
                    }
                    Spacer()
                    Text("CPU \(app.cpu, specifier: "%.0f")%").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).monospacedDigit()
                    Text(FS.format(app.memory)).monospacedDigit().frame(width: 90, alignment: .trailing)
                    PillButton(title: L("退出", "Quit")) { model.quit(app) }
                }
                .padding(.vertical, 3)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } footer: {
            Text(L("内存已用 \(FS.format(model.memoryUsed)) / \(FS.format(model.memoryTotal))。退出前记得保存正在编辑的内容。", "Memory used: \(FS.format(model.memoryUsed)) / \(FS.format(model.memoryTotal)). Save your work before quitting an app."))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            PillButton(title: L("刷新", "Refresh"), icon: "arrow.clockwise") { model.refreshHeavy() }
        }
    }
}
