import AppKit
import Foundation

/// 文件系统小工具：路径、体积、移到废纸篓。
enum FS {
    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser

    static func url(_ relativeToHome: String) -> URL {
        home.appendingPathComponent(relativeToHome)
    }

    static func exists(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func children(of url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    private static let sizeKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// 磁盘实际占用（递归目录，不跟随符号链接）。
    static func size(of url: URL) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: sizeKeys) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isRegularFile == true {
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        guard let e = fm.enumerator(
            at: url, includingPropertiesForKeys: Array(sizeKeys), options: [],
            errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            guard let fv = try? f.resourceValues(forKeys: sizeKeys), fv.isRegularFile == true else { continue }
            total += Int64(fv.totalFileAllocatedSize ?? fv.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func format(_ bytes: Int64) -> String {
        bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func abbreviate(_ path: String) -> String {
        path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
    }
}

/// 跨线程的取消标记。
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

enum Permissions {
    /// 只有拿到“完全磁盘访问权限”才能读的位置；任何一个能读就算有权限。
    static let probes: [(path: String, isDirectory: Bool)] = [
        ("Library/Application Support/com.apple.TCC/TCC.db", false),
        ("Library/Safari", true),
        ("Library/Mail", true),
        (".Trash", true),
    ]

    static func probeResults() -> [(String, Bool?)] {
        probes.map { probe -> (String, Bool?) in
            let url = FS.url(probe.path)
            guard FS.exists(url) else { return (probe.path, nil) }  // 不存在，无法判断
            if probe.isDirectory {
                return (probe.path, (try? FS.fm.contentsOfDirectory(atPath: url.path)) != nil)
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return (probe.path, false) }
            try? handle.close()
            return (probe.path, true)
        }
    }

    static func hasFullDiskAccess() -> Bool {
        probeResults().contains { $0.1 == true }
    }

    /// 权限要重新启动才生效：开一个新实例，再退出自己。
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct CleanFailure: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let reason: String
}

struct CleanResult: Identifiable {
    let id = UUID()
    var trashedCount = 0
    var trashedBytes: Int64 = 0
    var deletedCount = 0
    var deletedBytes: Int64 = 0
    var failures: [CleanFailure] = []

    var summary: String {
        var parts: [String] = []
        if trashedCount > 0 { parts.append(L("已将 \(trashedCount) 项（\(FS.format(trashedBytes))）移到废纸篓", "Moved \(plural(trashedCount, "item", "items")) (\(FS.format(trashedBytes))) to the Trash")) }
        if deletedCount > 0 { parts.append(L("已永久删除 \(deletedCount) 项，释放 \(FS.format(deletedBytes))", "permanently deleted \(plural(deletedCount, "item", "items")), freeing \(FS.format(deletedBytes))")) }
        if parts.isEmpty { parts.append(L("没有清理任何项目", "Nothing was cleaned")) }
        return parts.joined(separator: L("；", "; "))
    }
}

/// 执行清理：默认移到废纸篓，只有 permanent 的目标（废纸篓里的东西）才真正删除。
enum Cleaner {
    struct Target {
        let url: URL
        let size: Int64
        let permanent: Bool
    }

    static func perform(_ targets: [Target]) -> CleanResult {
        var result = CleanResult()
        if DebugFlags.readOnly {
            result.trashedCount = targets.filter { !$0.permanent }.count
            result.trashedBytes = targets.filter { !$0.permanent }.reduce(0) { $0 + $1.size }
            result.deletedCount = targets.filter(\.permanent).count
            result.deletedBytes = targets.filter(\.permanent).reduce(0) { $0 + $1.size }
            return result
        }
        // 先移废纸篓，再永久删除，避免顺序问题
        for t in targets.sorted(by: { !$0.permanent && $1.permanent }) {
            // 启动代理先从 launchd 卸载，否则删掉 plist 后进程还会一直跑到注销
            if t.url.deletingLastPathComponent().lastPathComponent == "LaunchAgents" {
                LaunchAgents.bootout(t.url)
            }
            do {
                if t.permanent {
                    try FS.fm.removeItem(at: t.url)
                    result.deletedCount += 1
                    result.deletedBytes += t.size
                } else {
                    try FS.fm.trashItem(at: t.url, resultingItemURL: nil)
                    result.trashedCount += 1
                    result.trashedBytes += t.size
                }
            } catch {
                result.failures.append(CleanFailure(path: t.url.path, reason: error.localizedDescription))
            }
        }
        return result
    }
}

enum LaunchAgents {
    /// launchctl bootout gui/<uid> <plist>；没加载时会失败，忽略即可。
    static func bootout(_ plist: URL) {
        guard !DebugFlags.readOnly else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())", plist.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// 启动代理指向的可执行文件（绝对路径）已经不存在。
    static func isBroken(_ plist: URL) -> Bool {
        guard let d = NSDictionary(contentsOf: plist) as? [String: Any] else { return false }
        let program = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first
        guard let program, program.hasPrefix("/") else { return false }
        return !FS.exists(URL(fileURLWithPath: program))
    }
}
