import AppKit
import SwiftUI

struct LargeFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var folder: String { FS.abbreviate(url.deletingLastPathComponent().path) }
}

enum LargeFileScanner {
    /// 遍历主目录（跳过 ~/Library、隐藏文件和应用包内部），找出超过阈值的文件。
    static func scan(
        root: URL, threshold: Int64, cancel: CancelFlag, progress: (Int, String) -> Void
    ) -> [LargeFile] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .contentModificationDateKey,
        ]
        let skipped: Set<String> = [FS.url("Library").path, FS.url(".Trash").path]
        guard let e = FS.fm.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true })
        else { return [] }

        var found: [LargeFile] = []
        var count = 0
        for case let url as URL in e {
            if cancel.isCancelled { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if skipped.contains(url.path) { e.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true else { continue }
            count += 1
            if count % 500 == 0 { progress(count, FS.abbreviate(url.deletingLastPathComponent().path)) }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            if size >= threshold {
                found.append(LargeFile(url: url, size: size, modified: v.contentModificationDate ?? .distantPast))
            }
        }
        progress(count, "")
        return found.sorted { $0.size > $1.size }
    }
}
