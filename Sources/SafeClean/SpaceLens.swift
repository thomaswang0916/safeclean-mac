import AppKit
import SwiftUI

// MARK: - 目录树

/// 空间透镜里的一个节点：文件夹（有子节点）或较大的文件。
final class SpaceNode: Identifiable, @unchecked Sendable {
    let url: URL
    let isDirectory: Bool
    var size: Int64
    var children: [SpaceNode] = []
    /// 小于 1 MB 的文件不单独建节点，合计在这里
    var looseSize: Int64 = 0
    var looseCount = 0
    weak var parent: SpaceNode?

    init(url: URL, isDirectory: Bool, size: Int64 = 0) {
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
    }

    var id: URL { url }
    var name: String { url.path == "/" ? "Macintosh HD" : url.lastPathComponent }
    var canDrill: Bool { isDirectory && (!children.isEmpty || looseCount > 0) }

    /// 删除一个子节点并把大小从祖先里扣掉
    func remove(_ child: SpaceNode) {
        children.removeAll { $0 === child }
        var node: SpaceNode? = self
        while let n = node {
            n.size -= child.size
            node = n.parent
        }
    }
}

enum SpaceScanner {
    /// 扫描整个磁盘时跳过的系统目录（/System 下的数据卷会和 /Users 等重复计算）
    static let skippedAtDiskRoot: Set<String> = ["/System", "/Volumes", "/dev", "/cores", "/private/var/vm"]

    static func scan(root: URL, includeHidden: Bool, cancel: CancelFlag, progress: @escaping (Int, String) -> Void) -> SpaceNode {
        let node = SpaceNode(url: root, isDirectory: true)
        var count = 0
        build(node, includeHidden: includeHidden, cancel: cancel, count: &count, progress: progress)
        progress(count, "")
        return node
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    private static func build(
        _ node: SpaceNode, includeHidden: Bool, cancel: CancelFlag, count: inout Int, progress: @escaping (Int, String) -> Void
    ) {
        guard !cancel.isCancelled else { return }
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let items = try? FS.fm.contentsOfDirectory(at: node.url, includingPropertiesForKeys: keys, options: options) else { return }
        for url in items {
            if cancel.isCancelled { return }
            if skippedAtDiskRoot.contains(url.path) { continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            count += 1
            if count % 3000 == 0 { progress(count, FS.abbreviate(node.url.path)) }
            if v.isDirectory == true {
                let child = SpaceNode(url: url, isDirectory: true)
                child.parent = node
                build(child, includeHidden: includeHidden, cancel: cancel, count: &count, progress: progress)
                if child.size > 0 {
                    node.children.append(child)
                    node.size += child.size
                }
            } else {
                let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                node.size += size
                if size >= 1_000_000 {
                    let child = SpaceNode(url: url, isDirectory: false, size: size)
                    child.parent = node
                    node.children.append(child)
                } else {
                    node.looseSize += size
                    node.looseCount += 1
                }
            }
        }
        node.children.sort { $0.size > $1.size }
    }
}

// MARK: - 方块图布局

/// Squarified treemap：把一组数值排成尽量接近正方形的矩形。输入需从大到小排好。
enum Treemap {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var result: [CGRect] = []
        var remaining = rect
        var row: [Double] = []
        var i = 0
        while i < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [areas[i]], side) <= worst(row, side) {
                row.append(areas[i])
                i += 1
            } else {
                place(row, in: &remaining, into: &result)
                row = []
            }
        }
        if !row.isEmpty { place(row, in: &remaining, into: &result) }
        return result
    }

    private static func worst(_ row: [Double], _ side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, let mx = row.max(), let mn = row.min(), mn > 0 else { return .infinity }
        return max(side * side * mx / (sum * sum), (sum * sum) / (side * side * mn))
    }

    private static func place(_ row: [Double], in rect: inout CGRect, into out: inout [CGRect]) {
        let sum = row.reduce(0, +)
        if rect.width >= rect.height {
            let width = sum / Double(rect.height)
            var y = Double(rect.minY)
            for area in row {
                let h = area / width
                out.append(CGRect(x: Double(rect.minX), y: y, width: width, height: h))
                y += h
            }
            rect = CGRect(x: rect.minX + width, y: rect.minY, width: max(0, rect.width - width), height: rect.height)
        } else {
            let height = sum / Double(rect.width)
            var x = Double(rect.minX)
            for area in row {
                let w = area / height
                out.append(CGRect(x: x, y: Double(rect.minY), width: w, height: height))
                x += w
            }
            rect = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: max(0, rect.height - height))
        }
    }
}

// MARK: - 状态

@MainActor
final class SpaceLensModel: ObservableObject {
    enum Screen { case intro, scanning, map, trashing }

    @Published var screen: Screen = .intro
    @Published var root: URL = FS.home
    @Published var includeHidden = true
    @Published var tree: SpaceNode?
    @Published var current: SpaceNode?
    @Published var selection = Set<URL>()
    @Published var status = ""
    @Published var message: String?
    @Published private(set) var revision = 0
    private var flag: CancelFlag?

    var rootName: String {
        switch root.path {
        case "/": L("Macintosh HD（整个磁盘）", "Macintosh HD (entire disk)")
        case FS.home.path: L("主目录（\(FS.home.lastPathComponent)）", "Home (\(FS.home.lastPathComponent))")
        default: root.lastPathComponent
        }
    }

    func choose(_ url: URL) { root = url }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root
        panel.prompt = L("选择", "Choose")
        if panel.runModal() == .OK, let url = panel.url { root = url }
    }

    func scan() {
        let flag = CancelFlag()
        self.flag = flag
        screen = .scanning
        status = L("准备中", "Getting ready")
        selection = []
        let root = root
        let includeHidden = includeHidden
        Task {
            let tree = await Task.detached(priority: .userInitiated) { [weak self] in
                SpaceScanner.scan(root: root, includeHidden: includeHidden, cancel: flag) { count, folder in
                    Task { @MainActor in self?.status = L("已查看 \(count) 项  \(folder)", "Checked \(plural(count, "item", "items"))  \(folder)") }
                }
            }.value
            guard !flag.isCancelled else { return }
            self.tree = tree
            current = tree
            screen = .map
        }
    }

    func stop() {
        flag?.cancel()
        screen = .intro
    }

    var breadcrumb: [SpaceNode] {
        var chain: [SpaceNode] = []
        var node = current
        while let n = node {
            chain.insert(n, at: 0)
            node = n.parent
        }
        return chain
    }

    var selectedNodes: [SpaceNode] {
        guard let tree else { return [] }
        var found: [SpaceNode] = []
        func walk(_ n: SpaceNode) {
            if selection.contains(n.url) { found.append(n); return }
            n.children.forEach(walk)
        }
        walk(tree)
        return found
    }

    func toggle(_ node: SpaceNode) {
        if selection.contains(node.url) { selection.remove(node.url) } else { selection.insert(node.url) }
    }

    func trashSelected() {
        let nodes = selectedNodes
        guard !nodes.isEmpty else { return }
        screen = .trashing
        Task {
            let targets = nodes.map { Cleaner.Target(url: $0.url, size: $0.size, permanent: false) }
            let r = await Task.detached { Cleaner.perform(targets) }.value
            StatsStore.shared.record(.personal, r)
            let failed = Set(r.failures.map(\.path))
            for node in nodes where !failed.contains(node.url.path) { node.parent?.remove(node) }
            selection = []
            message = r.failures.isEmpty ? r.summary : L("\(r.summary)；\(r.failures.count) 项没能移走", "\(r.summary); \(plural(r.failures.count, "item", "items")) couldn't be moved")
            revision += 1
            screen = .map
        }
    }
}

// MARK: - 界面

struct SpaceLensView: View {
    @ObservedObject var model: SpaceLensModel
    @ObservedObject var disk: DiskModel
    @State private var confirming = false
    private let module = Module.spaceLens

    var body: some View {
        Group {
            switch model.screen {
            case .intro:
                VStack(spacing: 0) {
                    StageTopBar(title: module.title)
                    ModuleIntro(module: module, action: { model.scan() }) {
                        VStack(alignment: .leading, spacing: 10) {
                            Menu {
                                Button(L("主目录", "Home")) { model.choose(FS.home) }
                                Button(L("Macintosh HD（整个磁盘，较慢）", "Macintosh HD (entire disk, slower)")) { model.choose(URL(fileURLWithPath: "/")) }
                                Button(L("应用程序", "Applications")) { model.choose(URL(fileURLWithPath: "/Applications")) }
                                Divider()
                                Button(L("选择文件夹…", "Choose Folder…")) { model.chooseFolder() }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: model.root.path == "/" ? "internaldrive.fill" : "folder.fill")
                                    Text(model.rootName).lineLimit(1)
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
                            Toggle(L("包括隐藏的文件", "Include hidden files"), isOn: $model.includeHidden).toggleStyle(.checkbox)
                        }
                        .padding(.top, 8)
                    }
                }
            case .scanning:
                VStack(spacing: 0) {
                    StageTopBar(title: module.title)
                    ScanningStage(module: module, title: L("正在测量空间…", "Measuring space…"), detail: model.status) { model.stop() }
                }
            case .map, .trashing:
                map
            }
        }
        .alert(L("移到废纸篓？", "Move to Trash?"), isPresented: $confirming) {
            Button(L("移到废纸篓", "Move to Trash"), role: .destructive) { model.trashSelected() }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            let nodes = model.selectedNodes
            Text(L("\(nodes.count) 项（\(FS.format(nodes.reduce(0) { $0 + $1.size }))）会被移到废纸篓，需要时可以放回。", "\(plural(nodes.count, "item", "items")) (\(FS.format(nodes.reduce(0) { $0 + $1.size }))) will be moved to the Trash. You can put them back if needed."))
        }
        .onChange(of: model.revision) { _, _ in disk.refresh() }
    }

    private var map: some View {
        VStack(spacing: 10) {
            StageTopBar(leadingTitle: L("重新开始", "Start Over"), leadingAction: { model.screen = .intro }, title: module.title)
            if let current = model.current {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Breadcrumb(model: model)
                        TreemapView(node: current, model: model, accent: module.accent)
                            .id("\(current.url.path)#\(model.revision)")
                    }
                    SpaceSidebar(node: current, model: model, accent: module.accent) { confirming = true }
                        .frame(width: 330)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
            }
        }
        .foregroundStyle(.white)
        .overlay {
            if model.screen == .trashing { ProgressView().controlSize(.large) }
        }
    }
}

struct Breadcrumb: View {
    @ObservedObject var model: SpaceLensModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.breadcrumb.enumerated()), id: \.element.id) { index, node in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5)) }
                Button(node.name) { model.current = node }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: index == model.breadcrumb.count - 1 ? .bold : .medium))
                    .foregroundStyle(.white.opacity(index == model.breadcrumb.count - 1 ? 1 : 0.7))
            }
            Spacer()
            if let current = model.current {
                Text(FS.format(current.size)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
            }
        }
        .lineLimit(1)
    }
}

/// 方块图：每块的面积和占用空间成正比。点文件夹进入下一层，点文件勾选。
struct TreemapView: View {
    let node: SpaceNode
    @ObservedObject var model: SpaceLensModel
    let accent: Color

    private struct Tile: Identifiable {
        let id: String
        let node: SpaceNode?
        let title: String
        let size: Int64
        let rect: CGRect
    }

    var body: some View {
        GeometryReader { geo in
            let tiles = layout(in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    TileView(
                        title: tile.title, size: tile.size, isFolder: tile.node?.isDirectory ?? false,
                        selected: tile.node.map { model.selection.contains($0.url) } ?? false,
                        color: color(index: index, node: tile.node), enabled: tile.node != nil
                    ) {
                        guard let n = tile.node else { return }
                        if n.canDrill { model.current = n } else { model.toggle(n) }
                    }
                    .frame(width: max(tile.rect.width - 4, 0), height: max(tile.rect.height - 4, 0))
                    .offset(x: tile.rect.minX + 2, y: tile.rect.minY + 2)
                    // offset 不改变布局位置，演示用的目标框单独按实际位置摆
                    .background(alignment: .topLeading) {
                        Color.clear
                            .frame(width: max(tile.rect.width - 4, 0), height: max(tile.rect.height - 4, 0))
                            .demoTarget("tile:" + tile.title)
                            .padding(.leading, tile.rect.minX + 2)
                            .padding(.top, tile.rect.minY + 2)
                    }
                    .contextMenu {
                        if let n = tile.node {
                            Button(model.selection.contains(n.url) ? L("取消勾选", "Deselect") : L("勾选", "Select")) { model.toggle(n) }
                            Button(L("在 Finder 中显示", "Show in Finder")) { FS.reveal([n.url]) }
                        }
                    }
                }
            }
        }
        .padding(6)
        .glass(cornerRadius: 22, opacity: 0.06)
    }

    private func layout(in rect: CGRect) -> [Tile] {
        let shown = Array(node.children.prefix(60))
        let rest = node.children.dropFirst(60).reduce(0) { $0 + $1.size }
        var entries: [(String, SpaceNode?, String, Int64)] = shown.map { ($0.url.path, $0, $0.name, $0.size) }
        if node.looseSize > 0 { entries.append(("#loose", nil, L("\(node.looseCount) 个小文件", "\(plural(node.looseCount, "small file", "small files"))"), node.looseSize)) }
        if rest > 0 { entries.append(("#rest", nil, L("其余 \(node.children.count - 60) 项", "\(plural(node.children.count - 60, "more item", "more items"))"), rest)) }
        entries.sort { $0.3 > $1.3 }
        let rects = Treemap.layout(entries.map { Double(max($0.3, 1)) }, in: rect)
        return zip(entries, rects).map { Tile(id: $0.0, node: $0.1, title: $0.2, size: $0.3, rect: $1) }
    }

    private func color(index: Int, node: SpaceNode?) -> Color {
        guard let node else { return .white.opacity(0.12) }
        if !node.isDirectory { return Color(hex: 0x8EA2C8).opacity(0.55) }
        let palette: [UInt32] = [0x8B6CFF, 0x4F8BFF, 0x2CC8C0, 0xE45FB4, 0xF29A4A, 0x6C5CE7, 0x3FB4F0, 0xB86CF2]
        return Color(hex: palette[index % palette.count]).opacity(0.85)
    }
}

struct TileView: View {
    let title: String
    let size: Int64
    let isFolder: Bool
    let selected: Bool
    let color: Color
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .brightness(hovering && enabled ? 0.08 : 0)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(selected ? 0.95 : 0.18), lineWidth: selected ? 2.5 : 1)
                    if geo.size.width > 64 && geo.size.height > 34 {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if isFolder { Image(systemName: "folder.fill").font(.system(size: 10)) }
                                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            }
                            Text(FS.format(size)).font(.system(size: 11)).opacity(0.85).monospacedDigit()
                        }
                        .padding(8)
                    }
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(6)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(title)  \(FS.format(size))")
    }
}

struct SpaceSidebar: View {
    let node: SpaceNode
    @ObservedObject var model: SpaceLensModel
    let accent: Color
    let confirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(node.children.prefix(200)) { child in
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { model.selection.contains(child.url) }, set: { _ in model.toggle(child) })) {
                            EmptyView()
                        }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        Image(nsImage: NSWorkspace.shared.icon(forFile: child.url.path)).resizable().frame(width: 18, height: 18)
                        Text(child.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(FS.format(child.size)).monospacedDigit().foregroundStyle(.secondary)
                        if child.canDrill {
                            Button { model.current = child } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            Divider().overlay(Color.white.opacity(0.12))
            VStack(alignment: .leading, spacing: 8) {
                if let message = model.message {
                    Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                }
                let selected = model.selectedNodes
                HStack {
                    Text(L("已选 \(selected.count) 项 · \(FS.format(selected.reduce(0) { $0 + $1.size }))", "\(selected.count) selected · \(FS.format(selected.reduce(0) { $0 + $1.size }))"))
                        .font(.system(size: 13))
                        .monospacedDigit()
                    Spacer()
                    ActionCapsule(title: L("移到废纸篓", "Move to Trash"), accent: accent, disabled: selected.isEmpty, action: confirm)
                }
            }
            .padding(14)
        }
        .glass(cornerRadius: 22, opacity: 0.07)
    }
}
