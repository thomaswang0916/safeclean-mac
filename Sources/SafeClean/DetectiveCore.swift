import AppKit
import Darwin
import Foundation

// MARK: - 存储位置

enum DetectiveStore {
    static let folder = FS.url("Library/Application Support/SafeClean")
    static let snapshotsURL = folder.appendingPathComponent("snapshots.json")
    static let regrowthURL = folder.appendingPathComponent("regrowth.json")
    static let maxSnapshots = 400

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        try? FS.fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - 快照：可用空间 + 各位置大小 + 各进程累计写入量

struct SpaceSnapshot: Codable {
    struct Proc: Codable {
        let name: String
        let written: UInt64
    }

    let date: Date
    let free: Int64
    /// 位置（~/Desktop、~/Library/Containers/com.tencent.xinWeChat、/System/Volumes/VM …）→ 占用
    let locations: [String: Int64]
    /// "pid:启动时间" → 进程名和启动以来累计写入的字节数
    let processes: [String: Proc]
}

enum SpaceRecorder {
    /// ~/Library 下这几个目录逐个子目录记录（增长通常藏在这里，比如微信、Docker）
    static let detailedLibraryDirs: Set<String> = ["Containers", "Application Support", "Group Containers", "Caches", "Developer"]

    /// 系统数据里能测量的位置
    static var systemLocations: [String] {
        var list = ["/Applications", "/System/Volumes/VM", "/cores", "/Library/Updates", "/System/Library/AssetsV2"]
        if let user = userTempRoot { list.append(user.path) }
        return list
    }

    /// /var/folders/xx/yyy：本用户的临时文件和系统缓存（DARWIN_USER_DIR 的上一级）
    static var userTempRoot: URL? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        guard tmp.path.contains("/var/folders/") else { return nil }
        return tmp.deletingLastPathComponent()
    }

    static func takeSnapshot(progress: ((String) -> Void)? = nil) -> SpaceSnapshot {
        var locations: [String: Int64] = [:]
        func measure(_ url: URL) {
            progress?(FS.abbreviate(url.path))
            locations[FS.abbreviate(url.path)] = FS.size(of: url)
        }
        for child in FS.children(of: FS.home) where child.lastPathComponent != "Library" && child.lastPathComponent != ".Trash" {
            measure(child)
        }
        for child in FS.children(of: FS.url("Library")) {
            if detailedLibraryDirs.contains(child.lastPathComponent) {
                FS.children(of: child).forEach(measure)
            } else {
                measure(child)
            }
        }
        measure(FS.url(".Trash"))
        systemLocations.map { URL(fileURLWithPath: $0) }.forEach(measure)
        let free = (try? FS.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return SpaceSnapshot(date: .now, free: free, locations: locations.filter { $0.value > 0 }, processes: processSamples())
    }

    /// 读取每个能读到的进程启动以来写了多少字节（root 进程读不到）
    static func processSamples() -> [String: SpaceSnapshot.Proc] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var result: [String: SpaceSnapshot.Proc] = [:]
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            var info = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard status == 0, info.ri_diskio_byteswritten > 1_000_000 else { continue }
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, 256)
            result["\(pid):\(info.ri_proc_start_abstime)"] = .init(name: String(cString: name), written: info.ri_diskio_byteswritten)
        }
        return result
    }

    static func loadSnapshots() -> [SpaceSnapshot] {
        DetectiveStore.load([SpaceSnapshot].self, from: DetectiveStore.snapshotsURL) ?? []
    }

    @discardableResult
    static func record(progress: ((String) -> Void)? = nil) -> [SpaceSnapshot] {
        var all = loadSnapshots()
        all.append(takeSnapshot(progress: progress))
        if all.count > DetectiveStore.maxSnapshots { all.removeFirst(all.count - DetectiveStore.maxSnapshots) }
        DetectiveStore.save(all, to: DetectiveStore.snapshotsURL)
        return all
    }
}

// MARK: - 对比两次快照

struct SpaceChange {
    struct Item: Identifiable {
        let key: String
        let title: String
        let delta: Int64
        var id: String { key }
    }

    let from: Date
    let to: Date
    let freeLost: Int64
    let growth: [Item]
    let writers: [Item]
}

enum SpaceComparer {
    /// 系统进程的中文名
    static let friendlyNames: [String: String] = [
        "mds_stores": "聚焦索引（Spotlight）", "mds": "聚焦索引（Spotlight）", "corespotlightd": "聚焦索引（Spotlight）",
        "mdworker_shared": "聚焦索引（Spotlight）", "backupd": "时间机器", "cloudd": "iCloud 同步", "bird": "iCloud 云盘",
        "nsurlsessiond": "系统后台下载", "softwareupdated": "系统更新", "photoanalysisd": "照片分析", "photolibraryd": "照片图库",
        "cfprefsd": "偏好设置服务", "identityservicesd": "iMessage / FaceTime 服务", "usernotificationsd": "通知中心",
        "lsd": "启动服务", "kernel_task": "系统内核", "Autoupdate": "应用自动更新（Sparkle）", "mediaanalysisd": "照片 / 视频分析",
        "com.docker.backend": "Docker", "com.docker.virtualization": "Docker", "dockerd": "Docker",
    ]

    static func displayName(process: String) -> String {
        if let friendly = friendlyNames[process] { return friendly }
        // “Google Chrome Helper (Renderer)” → “Google Chrome”
        if let range = process.range(of: " Helper") { return String(process[..<range.lowerBound]) }
        return process
    }

    static func displayName(location: String) -> String {
        let last = (location as NSString).lastPathComponent
        let parent = ((location as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let systemNames: [String: String] = [
            "/System/Volumes/VM": "交换文件和休眠镜像", "/cores": "崩溃转储", "/Library/Updates": "系统更新残留",
            "/System/Library/AssetsV2": "系统资源下载", "/Applications": "应用程序", "~/.Trash": "废纸篓",
        ]
        if let name = systemNames[location] { return name }
        if location == SpaceRecorder.userTempRoot.map({ FS.abbreviate($0.path) }) { return "系统临时文件" }
        if last.contains(".") {
            // Group Containers 的目录名前面带团队 ID（比如 5A4RE8SF68.com.tencent.xinWeChat），去掉再试
            let candidates = [last, last.split(separator: ".").dropFirst().joined(separator: ".")]
            if let app = candidates.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
                return "\(app.deletingPathExtension().lastPathComponent)（\(parent)）"
            }
        }
        return location
    }

    /// 从 base 到 latest：可用空间少了多少、哪些位置长了、哪些进程写得多（逐段累加，进程重启也算得对）
    static func compare(_ snapshots: [SpaceSnapshot], since date: Date) -> SpaceChange? {
        guard let latest = snapshots.last, snapshots.count >= 2 else { return nil }
        let baseIndex = snapshots.lastIndex { $0.date <= date } ?? 0
        guard baseIndex < snapshots.count - 1 else { return nil }
        let base = snapshots[baseIndex]

        let growth = Set(base.locations.keys).union(latest.locations.keys).compactMap { key -> SpaceChange.Item? in
            let delta = (latest.locations[key] ?? 0) - (base.locations[key] ?? 0)
            return abs(delta) >= 50_000_000 ? SpaceChange.Item(key: key, title: displayName(location: key), delta: delta) : nil
        }
        .sorted { $0.delta > $1.delta }

        var written: [String: Int64] = [:]
        for i in (baseIndex + 1)..<snapshots.count {
            let previous = snapshots[i - 1].processes
            for (key, proc) in snapshots[i].processes {
                let before = previous[key]?.written ?? 0
                let delta = proc.written >= before ? proc.written - before : proc.written
                written[displayName(process: proc.name), default: 0] += Int64(delta)
            }
        }
        let writers = written.filter { $0.value >= 50_000_000 }
            .map { SpaceChange.Item(key: $0.key, title: $0.key, delta: $0.value) }
            .sorted { $0.delta > $1.delta }

        return SpaceChange(from: base.date, to: latest.date, freeLost: base.free - latest.free, growth: growth, writers: writers)
    }
}

// MARK: - 系统数据拆解

struct SystemDataItem: Identifiable {
    enum Action {
        case none
        case reveal(URL)
        case admin(command: String, label: String)
        case openURL(URL, label: String)
        case shell(command: String, label: String)
        case gotoPerformance
    }

    let id: String
    let icon: String
    let title: String
    let size: Int64?
    let detail: String
    let safe: String
    let action: Action
}

enum SystemDataInspector {
    static func swapUsed() -> Int64 {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? Int64(swap.xsu_used) : 0
    }

    static func localSnapshots() -> (backups: [String], updates: [String]) {
        let output = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).output
        let names = output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("com.apple.") }
        return (names.filter { $0.contains("TimeMachine") }, names.filter { $0.contains("os.update") })
    }

    static func inspect() -> [SystemDataItem] {
        var items: [SystemDataItem] = []
        let snaps = localSnapshots()
        let values = try? FS.home.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let purgeable = max(0, (values?.volumeAvailableCapacityForImportantUsage ?? 0) - Int64(values?.volumeAvailableCapacity ?? 0))

        if !snaps.backups.isEmpty {
            items.append(
                SystemDataItem(
                    id: "tm", icon: "clock.arrow.circlepath", title: "时间机器本地快照（\(snaps.backups.count) 个）", size: nil,
                    detail: "没连备份盘时，时间机器先把备份存在本机。系统会在空间不够时自动删除，属于“可清除”空间。",
                    safe: "可以删，删了只是少了本地的历史版本", action: .admin(command: "/usr/bin/tmutil deletelocalsnapshots /", label: "删除本地快照")))
        }
        if snaps.updates.contains(where: { $0.contains("MSUPrepareUpdate") }) || !snaps.updates.isEmpty {
            let pending = snaps.updates.contains { $0.contains("MSUPrepareUpdate") }
            items.append(
                SystemDataItem(
                    id: "osupdate", icon: "arrow.down.circle", title: pending ? "已下载、等待安装的系统更新" : "系统更新快照（\(snaps.updates.count) 个）",
                    size: nil,
                    detail: pending ? "macOS 已经把新版本下载并准备好了，安装完成后这部分空间会释放。" : "升级系统时留下的回退快照，系统会在之后自动清理。",
                    safe: pending ? "去“软件更新”安装即可释放" : "不用管，系统会自己处理",
                    action: pending
                        ? .openURL(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!, label: "打开软件更新") : .none))
        }
        if purgeable > 500_000_000 {
            items.append(
                SystemDataItem(
                    id: "purgeable", icon: "arrow.3.trianglepath", title: "可清除空间", size: purgeable,
                    detail: "快照、iCloud 已上传文件的本地副本等。磁盘紧张时系统会自动释放，所以“可用空间”有时会比想象中多。",
                    safe: "不用手动处理", action: .none))
        }
        let swap = swapUsed()
        let vm = FS.size(of: URL(fileURLWithPath: "/System/Volumes/VM"))
        items.append(
            SystemDataItem(
                id: "swap", icon: "memorychip", title: "交换文件（虚拟内存）", size: swap,
                detail: "内存不够时，系统把暂时不用的内存内容写到硬盘上。开的应用越多、越吃内存，这里越大。",
                safe: "不能直接删；退出占内存的应用或重启后会变小", action: .gotoPerformance))
        let sleepimage = URL(fileURLWithPath: "/System/Volumes/VM/sleepimage")
        if FS.exists(sleepimage) {
            items.append(
                SystemDataItem(
                    id: "sleepimage", icon: "moon.zzz", title: "休眠镜像", size: FS.size(of: sleepimage),
                    detail: "合盖深度休眠时用来保存内存内容，大小约等于内存。", safe: "系统需要，别动", action: .none))
        } else if vm > swap + 500_000_000 {
            items.append(
                SystemDataItem(
                    id: "vm", icon: "moon.zzz", title: "其他虚拟内存文件", size: vm - swap, detail: "休眠和内存管理用的文件。", safe: "系统需要，别动",
                    action: .none))
        }
        let cores = FS.size(of: URL(fileURLWithPath: "/cores"))
        if cores > 0 {
            items.append(
                SystemDataItem(
                    id: "cores", icon: "ant", title: "崩溃转储（/cores）", size: cores,
                    detail: "程序崩溃时生成的完整内存转储，单个就可能几个 GB，只有开发者调试时才有用。", safe: "可以删",
                    action: .admin(command: "/bin/rm -rf /cores/core.*", label: "删除崩溃转储")))
        }
        let assets = FS.size(of: URL(fileURLWithPath: "/System/Library/AssetsV2"))
        if assets > 0 {
            items.append(
                SystemDataItem(
                    id: "assets", icon: "square.and.arrow.down.on.square", title: "系统资源下载", size: assets,
                    detail: "字体、Siri 语音、Apple 智能模型、系统更新包等按需下载的资源，由系统管理。", safe: "别手动删，系统会自己清理过期的",
                    action: .reveal(URL(fileURLWithPath: "/System/Library/AssetsV2"))))
        }
        let updates = FS.size(of: URL(fileURLWithPath: "/Library/Updates"))
        if updates > 100_000_000 {
            items.append(
                SystemDataItem(
                    id: "updates", icon: "shippingbox", title: "系统更新残留（/Library/Updates）", size: updates,
                    detail: "下载过但没装完的更新包。", safe: "装完更新后会清掉；确认不装可以删",
                    action: .reveal(URL(fileURLWithPath: "/Library/Updates"))))
        }
        if let temp = SpaceRecorder.userTempRoot {
            items.append(
                SystemDataItem(
                    id: "tmp", icon: "tray.full", title: "系统临时文件和缓存（/var/folders）", size: FS.size(of: temp),
                    detail: "系统和应用的临时文件，很多在重启时清掉。", safe: "重启是最安全的清理方式", action: .reveal(temp)))
        }
        let docker = FS.url("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        if FS.exists(docker) {
            items.append(
                SystemDataItem(
                    id: "docker", icon: "shippingbox.fill", title: "Docker 虚拟磁盘", size: FS.size(of: docker),
                    detail: "所有镜像、容器、卷都在这一个文件里，删了项目它也不会自己变小。", safe: "在终端运行 docker system df 看明细，再用 docker system prune 清理",
                    action: .reveal(docker)))
        }
        let simulators = FS.url("Library/Developer/CoreSimulator/Devices")
        if FS.exists(simulators) {
            items.append(
                SystemDataItem(
                    id: "simulators", icon: "iphone.gen3", title: "iOS 模拟器", size: FS.size(of: simulators),
                    detail: "Xcode 模拟器里装的应用和数据。", safe: "删除已经不可用的模拟器很安全",
                    action: .shell(command: "/usr/bin/xcrun simctl delete unavailable", label: "删除不可用的模拟器")))
        }
        items.append(
            SystemDataItem(
                id: "spotlight", icon: "magnifyingglass", title: "聚焦索引（Spotlight）", size: nil,
                detail: "搜索用的索引，通常几个 GB，异常时能到上百 GB（有 V2EX 网友重建后释放了 100 多 GB）。普通权限测不到大小。",
                safe: "太大时用“性能 → 重建 Spotlight 索引”",
                action: .admin(command: "/usr/bin/du -sh /System/Volumes/Data/.Spotlight-V100", label: "测量大小（需要密码）")))
        return items
    }
}

// MARK: - 白清检测

/// 记录每次清理掉的东西，过 1 天、7 天再量一次，看长回来多少。
struct CleanedEntry: Codable, Identifiable {
    let path: String
    let size: Int64
    let date: Date
    var after1d: Int64?
    var after7d: Int64?
    var id: String { "\(path)#\(date.timeIntervalSince1970)" }

    /// 最近一次复查的结果
    var latest: (days: Int, size: Int64)? {
        if let s = after7d { return (7, s) }
        if let s = after1d { return (1, s) }
        return nil
    }

    var ratio: Double? { latest.map { size > 0 ? Double($0.size) / Double(size) : 0 } }
}

enum Regrowth {
    static let pointlessRatio = 0.5

    static func load() -> [CleanedEntry] { DetectiveStore.load([CleanedEntry].self, from: DetectiveStore.regrowthURL) ?? [] }

    static func record(_ items: [(path: String, size: Int64)]) {
        guard !items.isEmpty else { return }
        var all = load()
        all += items.filter { $0.size >= 1_000_000 }.map { CleanedEntry(path: $0.path, size: $0.size, date: .now) }
        if all.count > 3000 { all.removeFirst(all.count - 3000) }
        DetectiveStore.save(all, to: DetectiveStore.regrowthURL)
    }

    /// 到时间的条目量一下现在的大小
    @discardableResult
    static func runChecks(now: Date = .now) -> [CleanedEntry] {
        var all = load()
        var changed = false
        for i in all.indices {
            let age = now.timeIntervalSince(all[i].date)
            if all[i].after1d == nil, age >= 20 * 3600 {
                all[i].after1d = FS.size(of: URL(fileURLWithPath: all[i].path))
                changed = true
            }
            if all[i].after7d == nil, age >= 7 * 86400 {
                all[i].after7d = FS.size(of: URL(fileURLWithPath: all[i].path))
                changed = true
            }
        }
        if changed { DetectiveStore.save(all, to: DetectiveStore.regrowthURL) }
        return all
    }

    /// 每个路径最近一次清理的结论（给清理模块用）
    static func verdicts() -> [String: CleanedEntry] {
        var result: [String: CleanedEntry] = [:]
        for entry in load() where entry.latest != nil {
            if let existing = result[entry.path], existing.date > entry.date { continue }
            result[entry.path] = entry
        }
        return result
    }

    static func hint(for entry: CleanedEntry) -> String? {
        guard let latest = entry.latest, let ratio = entry.ratio, ratio >= pointlessRatio else { return nil }
        let days = latest.days == 1 ? "一天" : "一周"
        let grew = ratio >= 1 ? "\(days)内就全部长回来了（现在 \(FS.format(latest.size))）" : "\(days)内又长回 \(FS.format(latest.size))（\(Int(ratio * 100))%）"
        return "上次清掉 \(FS.format(entry.size))，\(grew)。清了腾不出空间，还会让应用重新生成缓存。"
    }
}

// MARK: - 后台记录（LaunchAgent）

enum BackgroundRecorder {
    static var label: String { (Bundle.main.bundleIdentifier ?? "SafeClean") + ".snapshot" }
    static var plistURL: URL { FS.url("Library/LaunchAgents/\(label).plist") }
    static let interval = 3 * 3600

    static var isEnabled: Bool { FS.exists(plistURL) }

    static func setEnabled(_ enabled: Bool) {
        let target = "gui/\(getuid())"
        Shell.run("/bin/launchctl", ["bootout", target, plistURL.path])
        if enabled {
            guard let executable = Bundle.main.executablePath else { return }
            let plist: [String: Any] = [
                "Label": label, "ProgramArguments": [executable, "--snapshot"], "StartInterval": interval, "RunAtLoad": false,
                "ProcessType": "Background", "LowPriorityIO": true, "Nice": 10,
            ]
            try? FS.fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: plistURL, atomically: true)
            Shell.run("/bin/launchctl", ["bootstrap", target, plistURL.path])
        } else {
            try? FS.fm.removeItem(at: plistURL)
        }
    }

    /// 应用被挪了位置时，更新启动代理里的路径
    static func refreshIfNeeded() {
        guard isEnabled, let d = NSDictionary(contentsOf: plistURL), let args = d["ProgramArguments"] as? [String],
            args.first != Bundle.main.executablePath
        else { return }
        setEnabled(true)
    }
}
