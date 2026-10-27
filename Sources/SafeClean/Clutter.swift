import AppKit
import CryptoKit
import SwiftUI
import Vision

// MARK: - 数据

struct ClutterFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date
    var selected = false
    var note: String? = nil

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var folder: String { FS.abbreviate(url.deletingLastPathComponent().path) }
}

/// 一组重复或相似的文件
struct FileGroup: Identifiable {
    let id = UUID()
    var files: [ClutterFile]
    var selectedSize: Int64 { files.filter(\.selected).reduce(0) { $0 + $1.size } }
}

enum ClutterKind: String, CaseIterable, Identifiable {
    case large, duplicates, similar, downloads
    var id: String { rawValue }

    var title: String {
        switch self {
        case .large: L("大型文件", "Large Files")
        case .duplicates: L("重复文件", "Duplicates")
        case .similar: L("相似图片", "Similar Photos")
        case .downloads: L("旧的下载项", "Old Downloads")
        }
    }

    var icon: String {
        switch self {
        case .large: "doc.fill"
        case .duplicates: "doc.on.doc.fill"
        case .similar: "photo.on.rectangle.angled"
        case .downloads: "arrow.down.circle.fill"
        }
    }

    var explanation: String {
        switch self {
        case .large: L("大于 100 MB 的文件，默认不勾，自己看哪些不要了。", "Files over 100 MB. Nothing is selected — pick the ones you no longer need.")
        case .duplicates: L("内容完全一样、不小于 1 MB 的文件。每组保留修改时间最早的一份，其余默认勾选。代码仓库、依赖目录和剪辑软件的素材库不参与比对。", "Identical files of 1 MB or more. The oldest copy in each group is kept and the rest are selected. Code repositories, dependency folders and video-editor libraries are skipped.")
        case .similar: L("看起来几乎一样的照片（连拍、截图、改过尺寸）。默认都不勾，挑出不要的。", "Photos that look nearly the same (bursts, screenshots, resized copies). Nothing is selected — pick the ones you don't want.")
        case .downloads: L("下载文件夹里 30 天以上没动过的东西，默认不勾。", "Things in Downloads untouched for 30+ days. Nothing is selected by default.")
        }
    }
}

// MARK: - 扫描

enum ClutterScanner {
    struct FileEntry {
        let url: URL
        let size: Int64
        let modified: Date
        /// 在 Git 仓库、依赖/构建目录或应用自己管理的数据目录里——这些地方的“重复”是故意的，不参与重复和相似比对
        var managed = false
    }

    /// 路径里出现这些目录名，说明文件由工具或应用管理
    static let managedComponents: Set<String> = [
        "node_modules", "bower_components", "dist", "build", "vendor", "Pods", "Carthage", "DerivedData", "target", "venv", ".venv",
        "site-packages", "__pycache__", "Library", "CapCut", "JianyingPro", "Audio Music Apps", "User Data",
    ]

    /// 重复文件只看不小于 1 MB 的
    static let duplicateMinSize: Int64 = 1_000_000

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]

    /// 遍历目录（跳过资源库、隐藏文件、应用包内部），收集不小于 minSize 的普通文件。
    static func walk(root: URL, minSize: Int64, cancel: CancelFlag, progress: (Int) -> Void) -> [FileEntry] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let skipped: Set<String> = [FS.url("Library").path, FS.url(".Trash").path]
        guard let e = FS.fm.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true })
        else { return [] }
        var out: [FileEntry] = []
        var count = 0
        var repos: [String] = []  // 当前所在的 Git 仓库（深度优先遍历，用栈维护）
        for case let url as URL in e {
            if cancel.isCancelled { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let path = url.path
            while let top = repos.last, !path.hasPrefix(top) { repos.removeLast() }
            if v.isDirectory == true {
                if skipped.contains(path) { e.skipDescendants() }
                if FS.exists(url.appendingPathComponent(".git")) { repos.append(path + "/") }
                continue
            }
            guard v.isRegularFile == true else { continue }
            count += 1
            if count % 1000 == 0 { progress(count) }
            let size = Int64(v.fileSize ?? v.totalFileAllocatedSize ?? 0)
            if size >= minSize {
                let managed = !repos.isEmpty || url.pathComponents.contains { managedComponents.contains($0) }
                out.append(FileEntry(url: url, size: size, modified: v.contentModificationDate ?? .distantPast, managed: managed))
            }
        }
        progress(count)
        return out
    }

    static func sha256(_ url: URL, limit: Int? = nil) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            guard let chunk = try? handle.read(upToCount: min(1 << 20, remaining)), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 先按大小分组，再比前 64 KB 的哈希，最后比完整哈希。每组保留最早的一份，其余默认勾选。
    static func duplicates(_ entries: [FileEntry], cancel: CancelFlag) -> [FileGroup] {
        let candidates = entries.filter { !$0.managed && $0.size >= duplicateMinSize }
        let bySize = Dictionary(grouping: candidates, by: \.size).values.filter { $0.count > 1 }
        var groups: [FileGroup] = []
        for sameSize in bySize {
            if cancel.isCancelled { break }
            let byHead = Dictionary(grouping: sameSize) { sha256($0.url, limit: 64 * 1024) ?? UUID().uuidString }
            for candidates in byHead.values where candidates.count > 1 {
                let byFull = Dictionary(grouping: candidates) { sha256($0.url) ?? UUID().uuidString }
                for same in byFull.values where same.count > 1 {
                    let sorted = same.sorted { $0.modified < $1.modified }
                    let files = sorted.enumerated().map { index, entry in
                        ClutterFile(
                            url: entry.url, size: entry.size, modified: entry.modified, selected: index > 0,
                            note: index == 0 ? L("保留", "Keep") : nil)
                    }
                    groups.append(FileGroup(files: files))
                }
            }
        }
        return groups.sorted { $0.selectedSize > $1.selectedSize }
    }

    /// 用系统的图像特征（Vision）比较照片，距离小于阈值的归为一组。
    static func similarImages(_ entries: [FileEntry], cancel: CancelFlag, progress: (Int, Int) -> Void) -> [FileGroup] {
        let images = entries.filter {
            !$0.managed && $0.size >= 30_000 && $0.size < 60_000_000 && imageExtensions.contains($0.url.pathExtension.lowercased())
        }
            .sorted { $0.modified > $1.modified }
            .prefix(1500)
        var prints: [(FileEntry, VNFeaturePrintObservation)] = []
        for (i, entry) in images.enumerated() {
            if cancel.isCancelled { break }
            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(url: entry.url)
            if (try? handler.perform([request])) != nil, let observation = request.results?.first {
                prints.append((entry, observation))
            }
            if i % 20 == 0 { progress(i, images.count) }
        }
        progress(images.count, images.count)

        // 并查集：距离够近的放进同一组
        var parent = Array(prints.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for i in prints.indices {
            if cancel.isCancelled { break }
            for j in (i + 1)..<prints.count {
                var distance: Float = 0
                guard (try? prints[i].1.computeDistance(&distance, to: prints[j].1)) != nil else { continue }
                if distance < 0.42 { parent[find(i)] = find(j) }
            }
        }
        let clusters = Dictionary(grouping: prints.indices, by: find).values.filter { $0.count > 1 }
        return clusters.map { members in
            let files = members.map { prints[$0].0 }.sorted { $0.size > $1.size }
            return FileGroup(
                files: files.enumerated().map { index, e in
                    ClutterFile(url: e.url, size: e.size, modified: e.modified, note: index == 0 ? L("最清晰", "Best") : nil)
                })
        }
        .sorted { $0.files.count > $1.files.count }
    }

    /// 下载文件夹第一层里 30 天以上没动过的东西（文件或文件夹）
    static func oldDownloads(days: Int = 30) -> [ClutterFile] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        return FS.children(of: FS.url("Downloads"))
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { url -> ClutterFile? in
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .addedToDirectoryDateKey])
                let date = max(v?.contentModificationDate ?? .distantPast, v?.addedToDirectoryDate ?? .distantPast)
                guard date < cutoff else { return nil }
                return ClutterFile(url: url, size: FS.size(of: url), modified: date)
            }
            .sorted { $0.size > $1.size }
    }
}

// MARK: - 状态

@MainActor
final class ClutterModel: ObservableObject {
    enum Screen: Equatable { case intro, scanning, overview, detail(ClutterKind), trashing, done }

    @Published var screen: Screen = .intro
    @Published var root: URL = FS.home
    @Published var status = ""
    @Published var progress: Double? = nil
    @Published var large: [ClutterFile] = []
    @Published var duplicates: [FileGroup] = []
    @Published var similar: [FileGroup] = []
    @Published var downloads: [ClutterFile] = []
    @Published var result: CleanResult?
    private var flag: CancelFlag?

    var rootName: String { root == FS.home ? L("主目录（\(FS.home.lastPathComponent)）", "Home (\(FS.home.lastPathComponent))") : root.lastPathComponent }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root
        panel.prompt = L("选择", "Choose")
        if panel.runModal() == .OK, let url = panel.url { root = url }
    }

    func scan() { Task { await runScan() } }

    func runScan(includeSimilar: Bool = true) async {
        let flag = CancelFlag()
        self.flag = flag
        screen = .scanning
        progress = nil
        status = L("正在查看文件…", "Looking at files…")
        let root = root
        let entries = await Task.detached(priority: .userInitiated) { [weak self] in
            ClutterScanner.walk(root: root, minSize: 100_000, cancel: flag) { count in
                Task { @MainActor in self?.status = L("已查看 \(count) 个文件", "Checked \(plural(count, "file", "files"))") }
            }
        }.value
        guard !flag.isCancelled else { return }
        large = entries.filter { $0.size >= 100_000_000 }.sorted { $0.size > $1.size }
            .map { ClutterFile(url: $0.url, size: $0.size, modified: $0.modified) }
        status = L("正在比对重复文件…", "Comparing duplicates…")
        duplicates = await Task.detached(priority: .userInitiated) { ClutterScanner.duplicates(entries, cancel: flag) }.value
        if includeSimilar {
            status = L("正在比对相似图片…", "Comparing similar photos…")
            similar = await Task.detached(priority: .userInitiated) { [weak self] in
                ClutterScanner.similarImages(entries, cancel: flag) { done, total in
                    Task { @MainActor in
                        self?.status = L("正在比对相似图片：\(done) / \(total)", "Comparing similar photos: \(done) / \(total)")
                        self?.progress = total > 0 ? Double(done) / Double(total) : nil
                    }
                }
            }.value
        }
        downloads = await Task.detached { ClutterScanner.oldDownloads() }.value
        guard !flag.isCancelled else { return }
        progress = nil
        screen = .overview
    }

    func stop() {
        flag?.cancel()
        screen = .intro
    }

    // MARK: 智能呵护用：只查下载文件夹里的重复文件

    @Published var downloadDuplicates: [FileGroup] = []

    func scanDownloadDuplicates() async {
        let flag = CancelFlag()
        downloadDuplicates = await Task.detached(priority: .userInitiated) {
            let entries = ClutterScanner.walk(root: FS.url("Downloads"), minSize: 10_000, cancel: flag) { _ in }
            return ClutterScanner.duplicates(entries, cancel: flag)
        }.value
    }

    func trashDownloadDuplicates() async -> CleanResult {
        let targets = downloadDuplicates.flatMap(\.files).filter(\.selected).map {
            Cleaner.Target(url: $0.url, size: $0.size, permanent: false)
        }
        let r = await Task.detached { Cleaner.perform(targets) }.value
        StatsStore.shared.record(.duplicates, r)
        downloadDuplicates = []
        return r
    }

    // MARK: 选择和统计

    func files(_ kind: ClutterKind) -> [ClutterFile] {
        switch kind {
        case .large: large
        case .downloads: downloads
        case .duplicates: duplicates.flatMap(\.files)
        case .similar: similar.flatMap(\.files)
        }
    }

    var allSelected: [ClutterFile] { ClutterKind.allCases.flatMap { files($0).filter(\.selected) } }

    func summary(_ kind: ClutterKind) -> String {
        switch kind {
        case .large, .downloads:
            let list = files(kind)
            return list.isEmpty ? L("没有找到", "None found") : L("\(list.count) 个 · \(FS.format(list.reduce(0) { $0 + $1.size }))", "\(list.count) · \(FS.format(list.reduce(0) { $0 + $1.size }))")
        case .duplicates:
            return duplicates.isEmpty
                ? L("没有找到", "None found") : L("\(duplicates.count) 组 · 可省 \(FS.format(duplicates.reduce(0) { $0 + $1.files.dropFirst().reduce(0) { $0 + $1.size } }))", "\(plural(duplicates.count, "group", "groups")) · save \(FS.format(duplicates.reduce(0) { $0 + $1.files.dropFirst().reduce(0) { $0 + $1.size } }))")
        case .similar:
            return similar.isEmpty ? L("没有找到", "None found") : L("\(similar.count) 组 · \(similar.reduce(0) { $0 + $1.files.count }) 张", "\(plural(similar.count, "group", "groups")) · \(plural(similar.reduce(0) { $0 + $1.files.count }, "photo", "photos"))")
        }
    }

    func trashSelected() {
        let chosen = allSelected
        guard !chosen.isEmpty else { return }
        screen = .trashing
        Task {
            let targets = chosen.map { Cleaner.Target(url: $0.url, size: $0.size, permanent: false) }
            let r = await Task.detached { Cleaner.perform(targets) }.value
            StatsStore.shared.record(.personal, r)
            let failed = Set(r.failures.map(\.path))
            let removed = Set(chosen.map(\.url).filter { !failed.contains($0.path) })
            large.removeAll { removed.contains($0.url) }
            downloads.removeAll { removed.contains($0.url) }
            duplicates = duplicates.map { var g = $0; g.files.removeAll { removed.contains($0.url) }; return g }.filter { $0.files.count > 1 }
            similar = similar.map { var g = $0; g.files.removeAll { removed.contains($0.url) }; return g }.filter { $0.files.count > 1 }
            result = r
            screen = .done
        }
    }
}

// MARK: - 界面

struct ClutterView: View {
    @ObservedObject var model: ClutterModel
    @ObservedObject var disk: DiskModel
    @State private var confirming = false
    private let module = Module.clutter

    var body: some View {
        Group {
            switch model.screen {
            case .intro:
                VStack(spacing: 0) {
                    StageTopBar(title: module.title)
                    ModuleIntro(module: module, action: { model.scan() }) {
                        FolderChooser(name: model.rootName, choose: model.chooseFolder) { model.root = FS.home }
                    }
                }
            case .scanning:
                VStack(spacing: 0) {
                    StageTopBar(title: module.title)
                    ScanningStage(module: module, title: L("正在整理…", "Tidying up…"), detail: model.status, progress: model.progress) { model.stop() }
                }
            case .overview:
                overview
            case .detail(let kind):
                ClutterDetail(model: model, kind: kind, confirm: { confirming = true }) { model.screen = .overview }
            case .trashing:
                VStack(spacing: 0) {
                    StageTopBar(title: module.title)
                    ScanningStage(module: module, title: L("正在移到废纸篓…", "Moving to the Trash…"), detail: "", stop: nil)
                }
            case .done:
                VStack(spacing: 0) {
                    StageTopBar(title: module.title)
                    ResultStage(
                        module: module, symbol: "checkmark.seal.fill", headline: L("整理完成", "All Tidied Up"), subline: model.result?.summary ?? "",
                        primaryTitle: L("完成", "Done"), primaryAction: { model.screen = .overview }
                    ) {
                        PillButton(title: L("打开废纸篓", "Open Trash"), icon: "trash") { NSWorkspace.shared.open(FS.url(".Trash")) }
                    }
                }
            }
        }
        .alert(L("移到废纸篓？", "Move to Trash?"), isPresented: $confirming) {
            Button(L("移到废纸篓", "Move to Trash"), role: .destructive) { model.trashSelected() }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("选中的 \(model.allSelected.count) 个文件（\(FS.format(model.allSelected.reduce(0) { $0 + $1.size }))）会被移到废纸篓，需要时可以放回。", "\(model.allSelected.count) selected files (\(FS.format(model.allSelected.reduce(0) { $0 + $1.size }))) will be moved to the Trash. You can put them back if needed."))
        }
        .onChange(of: model.screen) { _, _ in disk.refresh() }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            StageTopBar(leadingTitle: L("重新开始", "Start Over"), leadingAction: { model.screen = .intro }, title: module.title)
            StageLayout(module: module, symbol: module.heroSymbol) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("扫描了\(model.rootName)", "Scanned \(model.rootName)")).font(.system(size: 30, weight: .bold)).lineLimit(2)
                    Text(L("点开每一类看看，勾上不要的，统一移到废纸篓。", "Open each category, select what you don't need, and move it all to the Trash at once."))
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.78))
                    ForEach(ClutterKind.allCases) { kind in
                        ActionTile(icon: kind.icon, title: kind.title, value: model.summary(kind), accent: module.accent) {
                            model.screen = .detail(kind)
                        }
                    }
                }
            } bottom: {
                OrbButton(
                    title: L("移除", "Remove"), accent: module.accent, disabled: model.allSelected.isEmpty, action: { confirming = true })
            }
        }
    }
}

/// 介绍页里选择扫描范围的小控件
struct FolderChooser: View {
    let name: String
    let choose: () -> Void
    let reset: () -> Void

    var body: some View {
        Menu {
            Button(L("主目录", "Home"), action: reset)
            Button(L("选择文件夹…", "Choose Folder…"), action: choose)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                Text(name).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minWidth: 260, alignment: .leading)
            .glass(cornerRadius: 12, opacity: 0.12)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.top, 8)
    }
}

struct ClutterDetail: View {
    @ObservedObject var model: ClutterModel
    let kind: ClutterKind
    let confirm: () -> Void
    let back: () -> Void
    private let accent = Module.clutter.accent

    var body: some View {
        DetailFrame(title: kind.title, back: back) {
            VStack(alignment: .leading, spacing: 0) {
                Text(kind.explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                content
            }
        } footer: {
            let chosen = model.allSelected
            Text(L("已选 \(chosen.count) 个，共 \(FS.format(chosen.reduce(0) { $0 + $1.size }))", "\(chosen.count) selected, \(FS.format(chosen.reduce(0) { $0 + $1.size }))"))
                .foregroundStyle(.white.opacity(0.75))
                .monospacedDigit()
            Spacer()
            ActionCapsule(title: L("移到废纸篓", "Move to Trash"), accent: accent, disabled: chosen.isEmpty, action: confirm)
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .large:
            fileList($model.large)
        case .downloads:
            fileList($model.downloads)
        case .duplicates:
            groupList($model.duplicates, thumbnails: false)
        case .similar:
            groupList($model.similar, thumbnails: true)
        }
    }

    private func fileList(_ files: Binding<[ClutterFile]>) -> some View {
        List {
            if files.wrappedValue.isEmpty {
                Text(L("没有找到", "None found")).foregroundStyle(.secondary).listRowBackground(Color.clear)
            }
            ForEach(files) { $file in
                ClutterRow(file: $file, thumbnail: false).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func groupList(_ groups: Binding<[FileGroup]>, thumbnails: Bool) -> some View {
        List {
            if groups.wrappedValue.isEmpty {
                Text(L("没有找到", "None found")).foregroundStyle(.secondary).listRowBackground(Color.clear)
            }
            ForEach(groups) { $group in
                ListHeader(L("\(group.files.count) 个 · 每个 \(FS.format(group.files.first?.size ?? 0))", "\(plural(group.files.count, "file", "files")) · \(FS.format(group.files.first?.size ?? 0)) each"))
                ForEach($group.files) { $file in
                    ClutterRow(file: $file, thumbnail: thumbnails).listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

struct ClutterRow: View {
    @Binding var file: ClutterFile
    let thumbnail: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $file.selected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            if thumbnail, let image = Thumbnails.image(file.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                    .resizable()
                    .frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text(file.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let note = file.note {
                Text(note)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(hex: 0x4ADE80).opacity(0.22)))
                    .foregroundStyle(Color(hex: 0x86EFAC))
            }
            Spacer()
            Text(file.modified, format: .dateTime.year().month().day())
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(FS.format(file.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Button {
                FS.reveal([file.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(L("在 Finder 中显示", "Show in Finder"))
        }
        .padding(.vertical, 2)
    }
}

/// 用 ImageIO 生成小缩略图并缓存，不把整张大图读进内存。
enum Thumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(_ url: URL, maxPixel: Int = 120) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
