import AppKit
import SwiftUI

/// 整个应用的状态：各模块的数据模型都挂在这里，切换模块时不会丢。
@MainActor
final class AppState: ObservableObject {
    @Published var module: Module = .smartCare
    @Published var hasFullDiskAccess = Permissions.hasFullDiskAccess()

    let disk = DiskModel()
    let junk = JunkModel()
    let apps = AppsModel()
    let updates = UpdatesModel()
    let clutter = ClutterModel()
    let lens = SpaceLensModel()
    let performance = PerformanceModel()
    let stats = StatsModel()
    let detective = DetectiveModel()
    private(set) lazy var smartCare = SmartCareModel(state: self)

    func refreshPermissions() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        disk.refresh()
    }
}

struct RootView: View {
    @StateObject private var state = AppState()

    var body: some View {
        HStack(spacing: 0) {
            Rail(selection: $state.module, disk: state.disk)
            VStack(spacing: 0) {
                if !state.hasFullDiskAccess && !DebugFlags.hideBanner {
                    PermissionBanner()
                        .padding(.horizontal, 28)
                        .padding(.top, 14)
                }
                moduleView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(state.module)
                    .transition(.opacity)
            }
        }
        .background(ModuleBackground(module: state.module))
        .animation(.easeInOut(duration: 0.3), value: state.module)
        .frame(minWidth: 1040, minHeight: 700)
        .preferredColorScheme(.dark)
        .environment(\.locale, appLocale)
        .background(WindowConfigurator())
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshPermissions()
        }
        #if DEBUG
            .task { await DebugSnapshot.run(state: state) }
        #endif
    }

    @ViewBuilder private var moduleView: some View {
        switch state.module {
        case .smartCare: SmartCareView(model: state.smartCare, state: state)
        case .cleanup: CleanupView(model: state.junk, disk: state.disk)
        case .performance: PerformanceView(model: state.performance)
        case .applications: ApplicationsView(apps: state.apps, updates: state.updates, disk: state.disk)
        case .clutter: ClutterView(model: state.clutter, disk: state.disk)
        case .spaceLens: SpaceLensView(model: state.lens, disk: state.disk)
        case .detective: DetectiveView(model: state.detective, state: state)
        case .stats: StatsView(model: state.stats, state: state, disk: state.disk)
        }
    }
}

// MARK: - 左侧图标栏

struct Rail: View {
    @Binding var selection: Module
    @ObservedObject var disk: DiskModel

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Module.allCases.filter { $0 != .stats }) { module in
                RailButton(module: module, selected: selection == module) { selection = module }
            }
            Spacer()
            RailButton(module: .stats, selected: selection == .stats) { selection = .stats }
            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 52, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("设置", "Settings"))
            .padding(.bottom, 6)
            DiskRing(disk: disk)
        }
        .padding(.top, 54)
        .padding(.bottom, 18)
        .frame(width: 88)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.16))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.06)).frame(width: 1) }
    }
}

struct RailButton: View {
    let module: Module
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: module.icon)
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(selected || hovering ? 1 : 0.72))
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color.white.opacity(selected ? 0.2 : hovering ? 0.1 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(Color.white.opacity(selected ? 0.35 : 0), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(module.title)
        .overlay(alignment: .leading) {
            if hovering && !selected {
                Text(module.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .fixedSize()
                    .offset(x: 62)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(hovering ? 1 : 0)
    }
}

/// 图标栏底部的磁盘用量小圆环
struct DiskRing: View {
    @ObservedObject var disk: DiskModel

    var body: some View {
        let used = disk.total > 0 ? Double(disk.total - disk.free) / Double(disk.total) : 0
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: used)
                    .stroke(used > 0.9 ? Color.red : Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "internaldrive.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 40, height: 40)
            Text(L("可用\n\(FS.format(disk.free))", "Free\n\(FS.format(disk.free))"))
                .font(.system(size: 10, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
        }
        .help(L("Macintosh HD：可用 \(FS.format(disk.free))，共 \(FS.format(disk.total))", "Macintosh HD: \(FS.format(disk.free)) free of \(FS.format(disk.total))"))
    }
}

/// 让窗口标题栏透明、可以拖动背景移动窗口。
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            if DebugFlags.readOnly { window.ignoresMouseEvents = true }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - 磁盘用量

@MainActor
final class DiskModel: ObservableObject {
    @Published var total: Int64 = 0
    @Published var free: Int64 = 0

    init() { refresh() }

    func refresh() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? FS.home.resourceValues(forKeys: keys) else { return }
        total = Int64(v.volumeTotalCapacity ?? 0)
        free = v.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

// MARK: - 结果页

/// 扫描完的结果页：插画 + 大标题 + 说明 + 自定义内容 + 底部圆按钮。
struct ResultStage<Content: View>: View {
    let module: Module
    var symbol: String? = nil
    let headline: String
    let subline: String
    let primaryTitle: String
    var primaryDisabled = false
    let primaryAction: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        StageLayout(module: module, symbol: symbol ?? module.heroSymbol) {
            VStack(alignment: .leading, spacing: 14) {
                Text(headline)
                    .font(.system(size: 38, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subline)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                content.padding(.top, 8)
            }
        } bottom: {
            OrbButton(title: primaryTitle, accent: module.accent, disabled: primaryDisabled, action: primaryAction)
        }
    }
}

/// 详情页的外框：顶部返回 + 标题，中间一块玻璃面板，底部一条操作栏。
struct DetailFrame<Content: View, Footer: View>: View {
    let title: String
    let back: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 12) {
            StageTopBar(leadingTitle: L("返回", "Back"), leadingIcon: "chevron.left", leadingAction: back, title: title)
            VStack(spacing: 0) {
                content
                Divider().overlay(Color.white.opacity(0.12))
                HStack(spacing: 10) { footer }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            .glass(cornerRadius: 22, opacity: 0.07)
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
        .foregroundStyle(.white)
    }
}

/// 详情页底栏里的主按钮（实心胶囊）
struct ActionCapsule: View {
    let title: String
    let accent: Color
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 9)
                .background(Capsule().fill(LinearGradient(colors: [accent, accent.opacity(0.7)], startPoint: .top, endPoint: .bottom)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                .shadow(color: accent.opacity(0.6), radius: 10)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// 列表行里的小清单：图标 + 名称 + 大小
struct SummaryRow: View {
    let icon: String
    let title: String
    let value: String
    var accent: Color = .white

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.opacity(0.35)))
            Text(title).font(.system(size: 14, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
        }
    }
}
