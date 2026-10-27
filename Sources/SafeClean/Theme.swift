import AppKit
import SwiftUI

// MARK: - 模块

struct Feature: Identifiable {
    let icon: String
    let title: String
    var id: String { title }
}

/// 左侧图标栏里的每个功能模块，以及它的配色、插画和介绍。
enum Module: String, CaseIterable, Identifiable {
    case smartCare, cleanup, performance, applications, clutter, spaceLens, detective, stats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartCare: L("智能呵护", "Smart Care")
        case .cleanup: L("清理", "Cleanup")
        case .performance: L("性能", "Performance")
        case .applications: L("应用程序", "Applications")
        case .clutter: L("整理杂乱", "My Clutter")
        case .spaceLens: L("空间透镜", "Space Lens")
        case .detective: L("空间侦探", "Space Detective")
        case .stats: L("统计数据", "Statistics")
        }
    }

    var tagline: String {
        switch self {
        case .smartCare: L("一次扫描，把垃圾、杂乱、更新和性能问题一起找出来。", "One scan finds junk, clutter, outdated apps and performance issues all at once.")
        case .cleanup: L("清掉缓存、日志和开发残留，所有东西都先进废纸篓，随时能放回。", "Clear caches, logs and developer leftovers. Everything goes to the Trash first, so you can always put it back.")
        case .performance: L("运行维护任务，管理后台项，找出拖慢 Mac 的应用。", "Run maintenance tasks, manage background items and find the apps slowing your Mac down.")
        case .applications: L("彻底卸载应用和它留下的文件，检查哪些应用有新版本。", "Fully uninstall apps along with the files they leave behind, and check which apps have updates.")
        case .clutter: L("找出大文件、重复文件、相似照片和下载里的旧东西。", "Find large files, duplicates, similar photos and old stuff in Downloads.")
        case .spaceLens: L("一眼看清空间都被谁占了，一层层点进去找到元凶。", "See at a glance what's taking up space, then drill down folder by folder to find the culprit.")
        case .detective: L("空间去哪了、系统数据里是什么、哪些清理是白清。", "Where your space went, what's inside System Data, and which cleanups are pointless.")
        case .stats: L("清理记录和优化建议。", "Cleanup history and recommendations.")
        }
    }

    /// 图标栏里的小图标
    var icon: String {
        switch self {
        case .smartCare: "wand.and.stars"
        case .cleanup: "bubbles.and.sparkles"
        case .performance: "bolt.fill"
        case .applications: "square.grid.2x2.fill"
        case .clutter: "folder.fill"
        case .spaceLens: "circle.hexagongrid.fill"
        case .detective: "binoculars.fill"
        case .stats: "chart.line.uptrend.xyaxis"
        }
    }

    /// 介绍页插画里的大图标
    var heroSymbol: String {
        switch self {
        case .smartCare: "wand.and.stars"
        case .cleanup: "bubbles.and.sparkles.fill"
        case .performance: "bolt.fill"
        case .applications: "square.grid.2x2.fill"
        case .clutter: "folder.fill"
        case .spaceLens: "circle.hexagongrid.fill"
        case .detective: "binoculars.fill"
        case .stats: "chart.line.uptrend.xyaxis"
        }
    }

    /// 背景渐变（左上 → 右下）
    var colors: [Color] {
        switch self {
        case .smartCare: [Color(hex: 0x24104F), Color(hex: 0x4E1A86), Color(hex: 0x86206F)]
        case .cleanup: [Color(hex: 0x05261F), Color(hex: 0x0A4E3D), Color(hex: 0x10735A)]
        case .performance: [Color(hex: 0x2E0B0B), Color(hex: 0x6B1F10), Color(hex: 0x9C3A0E)]
        case .applications: [Color(hex: 0x0A1A42), Color(hex: 0x112E7A), Color(hex: 0x1B48C2)]
        case .clutter: [Color(hex: 0x052A31), Color(hex: 0x0A5059), Color(hex: 0x0E7470)]
        case .spaceLens: [Color(hex: 0x170D45), Color(hex: 0x2C1C82), Color(hex: 0x4726A0)]
        case .detective: [Color(hex: 0x081A2B), Color(hex: 0x0E3550), Color(hex: 0x135A70)]
        case .stats: [Color(hex: 0x14112E), Color(hex: 0x2A2360), Color(hex: 0x3A2A6E)]
        }
    }

    /// 按钮、光晕、强调色
    var accent: Color {
        switch self {
        case .smartCare: Color(hex: 0xC06BFF)
        case .cleanup: Color(hex: 0x3DDC97)
        case .performance: Color(hex: 0xFF9A4D)
        case .applications: Color(hex: 0x6AA8FF)
        case .clutter: Color(hex: 0x37E0C8)
        case .spaceLens: Color(hex: 0xA48BFF)
        case .detective: Color(hex: 0x5CD6FF)
        case .stats: Color(hex: 0x8B9CFF)
        }
    }

    var features: [Feature] {
        switch self {
        case .smartCare:
            [
                Feature(icon: "bubbles.and.sparkles.fill", title: L("系统垃圾", "System Junk")),
                Feature(icon: "doc.on.doc.fill", title: L("重复下载", "Duplicate Downloads")),
                Feature(icon: "arrow.down.app.fill", title: L("应用更新", "App Updates")),
                Feature(icon: "bolt.fill", title: L("性能建议", "Performance Tips")),
            ]
        case .cleanup:
            [
                Feature(icon: "archivebox.fill", title: L("应用缓存与日志", "App Caches & Logs")),
                Feature(icon: "hammer.fill", title: L("开发者垃圾", "Developer Junk")),
                Feature(icon: "bandage.fill", title: L("失效的启动项", "Broken Login Items")),
                Feature(icon: "trash.fill", title: L("废纸篓", "Trash")),
            ]
        case .performance:
            [
                Feature(icon: "wrench.and.screwdriver.fill", title: L("维护任务", "Maintenance Tasks")),
                Feature(icon: "switch.2", title: L("后台启动项", "Background Items")),
                Feature(icon: "gauge.with.dots.needle.67percent", title: L("高耗能应用", "Heavy Consumers")),
            ]
        case .applications:
            [
                Feature(icon: "xmark.bin.fill", title: L("彻底卸载", "Complete Uninstall")),
                Feature(icon: "arrow.down.app.fill", title: L("检查更新", "Update Check")),
                Feature(icon: "puzzlepiece.extension.fill", title: L("清理残留", "Leftover Cleanup")),
            ]
        case .clutter:
            [
                Feature(icon: "doc.fill", title: L("大型文件", "Large Files")),
                Feature(icon: "doc.on.doc.fill", title: L("重复文件", "Duplicates")),
                Feature(icon: "photo.on.rectangle.angled", title: L("相似图片", "Similar Photos")),
                Feature(icon: "arrow.down.circle.fill", title: L("旧的下载项", "Old Downloads")),
            ]
        case .spaceLens:
            [
                Feature(icon: "square.grid.3x3.square", title: L("存储空间分布图", "Storage Map")),
                Feature(icon: "eye.fill", title: L("显示被隐藏的文件", "Hidden Files Included")),
                Feature(icon: "folder.fill", title: L("大文件夹一览", "Largest Folders")),
            ]
        case .detective: []
        case .stats: []
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

// MARK: - 背景

struct ModuleBackground: View {
    let module: Module

    var body: some View {
        ZStack {
            LinearGradient(colors: module.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [module.accent.opacity(0.35), .clear], center: UnitPoint(x: 0.32, y: 0.48), startRadius: 0,
                endRadius: 520)
            RadialGradient(colors: [.white.opacity(0.07), .clear], center: .topTrailing, startRadius: 0, endRadius: 700)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.45), value: module)
    }
}

// MARK: - 玻璃面板

extension View {
    /// 半透明的玻璃卡片
    func glass(cornerRadius: CGFloat = 20, opacity: Double = 0.08) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.white.opacity(opacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
    }
}

// MARK: - 插画

/// 每个模块的插画：一块会轻轻浮动的玻璃方块，中间是发光的图标。全部用系统图标和渐变画出来。
struct HeroArt: View {
    let symbol: String
    let accent: Color
    var size: CGFloat = 300
    @State private var floating = false

    var body: some View {
        let radius = size * 0.28
        ZStack {
            Ellipse()
                .fill(accent.opacity(0.5))
                .frame(width: size * 0.9, height: size * 0.16)
                .blur(radius: 28)
                .offset(y: size * 0.6)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(0.75), accent.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-9))
                .offset(x: size * 0.07, y: size * 0.06)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.42), .white.opacity(0.12), accent.opacity(0.18)], startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.9), .white.opacity(0.15), accent.opacity(0.7)], startPoint: .topLeading,
                                endPoint: .bottomTrailing), lineWidth: 1.5)
                )
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 22)
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(LinearGradient(colors: [.white, accent], startPoint: .top, endPoint: .bottom))
                .shadow(color: accent.opacity(0.9), radius: 26)
        }
        .frame(width: size * 1.25, height: size * 1.35)
        .rotationEffect(.degrees(floating ? 1.5 : -1.5))
        .offset(y: floating ? -8 : 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) { floating = true }
        }
    }
}

// MARK: - 圆形主按钮

/// 底部中间的大圆按钮（扫描 / 清理 / 运行），扫描时外圈显示进度或转圈。
struct OrbButton: View {
    let title: String
    let accent: Color
    var busy = false
    var progress: Double? = nil
    var disabled = false
    let action: () -> Void
    @State private var pulse = false
    @State private var spin = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.35))
                    .frame(width: 150, height: 150)
                    .scaleEffect(pulse ? 1.15 : 0.92)
                    .opacity(pulse || busy ? 0 : 0.7)
                Circle()
                    .fill(LinearGradient(colors: [accent, accent.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1.5))
                    .frame(width: 120, height: 120)
                    .shadow(color: accent.opacity(0.8), radius: 26)
                if let progress {
                    Circle()
                        .trim(from: 0, to: max(0.02, min(progress, 1)))
                        .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 136, height: 136)
                        .animation(.easeOut(duration: 0.3), value: progress)
                } else if busy {
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 136, height: 136)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .onAppear {
                            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true }
                        }
                }
                Text(title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 160, height: 160)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .demoTarget("orb")
        .onAppear {
            guard !DebugFlags.readOnly else { return }
            withAnimation(.easeOut(duration: 1.9).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// 白色描边的胶囊按钮（查看详情、重新开始等）
struct PillButton: View {
    let title: String
    var icon: String? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.white.opacity(prominent ? 0.24 : 0.1)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .demoTarget("pill:" + title)
    }
}

// MARK: - 页面骨架

struct FeatureRow: View {
    let feature: Feature
    let accent: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: feature.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
            Text(feature.title).font(.system(size: 17, weight: .semibold))
        }
    }
}

/// 介绍页：左边插画，右边标题、说明、功能列表，底部中间大圆按钮。
struct ModuleIntro<Accessory: View>: View {
    let module: Module
    var buttonTitle = L("扫描", "Scan")
    let action: () -> Void
    @ViewBuilder var accessory: Accessory

    var body: some View {
        StageLayout(module: module, symbol: module.heroSymbol) {
            VStack(alignment: .leading, spacing: 22) {
                Text(module.title).font(.system(size: 46, weight: .bold))
                Text(module.tagline)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(module.features) { FeatureRow(feature: $0, accent: module.accent) }
                }
                .padding(.top, 6)
                accessory
            }
        } bottom: {
            OrbButton(title: buttonTitle, accent: module.accent, action: action)
        }
    }
}

extension ModuleIntro where Accessory == EmptyView {
    init(module: Module, buttonTitle: String = L("扫描", "Scan"), action: @escaping () -> Void) {
        self.init(module: module, buttonTitle: buttonTitle, action: action) { EmptyView() }
    }
}

/// 插画 + 右侧文字 + 底部按钮 的通用布局，介绍页、扫描中、结果页都用它。
struct StageLayout<Content: View, Bottom: View>: View {
    let module: Module
    let symbol: String
    @ViewBuilder var content: Content
    @ViewBuilder var bottom: Bottom

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 48) {
                HeroArt(symbol: symbol, accent: module.accent, size: 270)
                    .frame(maxWidth: .infinity)
                content
                    .frame(maxWidth: 440, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 48)
            .frame(maxHeight: .infinity)
            bottom
                .frame(height: 170)
                .padding(.bottom, 18)
        }
        .foregroundStyle(.white)
    }
}

/// 扫描中的页面
struct ScanningStage: View {
    let module: Module
    let title: String
    let detail: String
    var progress: Double? = nil
    let stop: (() -> Void)?

    var body: some View {
        StageLayout(module: module, symbol: module.heroSymbol) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 36, weight: .bold))
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .monospacedDigit()
            }
        } bottom: {
            OrbButton(title: stop == nil ? "" : L("停止", "Stop"), accent: module.accent, busy: true, progress: progress) { stop?() }
                .allowsHitTesting(stop != nil)
        }
    }
}

/// 页面顶部的一行：左边“重新开始”/“返回”，右边可放其他按钮。
struct StageTopBar<Trailing: View>: View {
    var leadingTitle: String? = nil
    var leadingIcon = "arrow.counterclockwise"
    var leadingAction: (() -> Void)? = nil
    var title: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            if let title {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
            HStack {
                if let leadingTitle, let leadingAction {
                    Button(action: leadingAction) {
                        Label(leadingTitle, systemImage: leadingIcon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                trailing
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 28)
        .padding(.top, 14)
    }
}

extension StageTopBar where Trailing == EmptyView {
    init(leadingTitle: String? = nil, leadingIcon: String = "arrow.counterclockwise", leadingAction: (() -> Void)? = nil, title: String? = nil) {
        self.init(leadingTitle: leadingTitle, leadingIcon: leadingIcon, leadingAction: leadingAction, title: title) { EmptyView() }
    }
}

/// 一个小的状态标签：绿色勾 + 文字
struct DoneChip: View {
    let text: String
    var color: Color = Color(hex: 0x4ADE80)

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
    }
}

/// 没有完全磁盘访问权限时，显示在页面顶部的提示条（玻璃样式）。
struct PermissionBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(Color(hex: 0xFFC46B))
            Text(L("没有“完全磁盘访问权限”，废纸篓、邮件附件、iOS 备份等位置扫描不到。", "No Full Disk Access — the Trash, Mail attachments, iOS backups and some other locations can't be scanned."))
                .font(.system(size: 13))
            Spacer(minLength: 8)
            PillButton(title: L("去设置", "Open Settings")) { Permissions.openFullDiskAccessSettings() }
            PillButton(title: L("重新打开", "Relaunch")) { Permissions.relaunch() }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(cornerRadius: 14, opacity: 0.1)
    }
}

/// 截图用的开关（只在 debug 构建里读环境变量，正式版永远是默认值）
enum DebugFlags {
    #if DEBUG
        static var hideBanner: Bool { ProcessInfo.processInfo.environment["SAFECLEAN_HIDE_BANNER"] != nil }
        static var deviceName: String? { ProcessInfo.processInfo.environment["SAFECLEAN_DEVICE_NAME"] }
        /// 截图 / 录演示视频时为真：所有会改动磁盘或系统的操作都只是假装执行
        static let readOnly: Bool = ProcessInfo.processInfo.environment["SAFECLEAN_SNAPSHOT"] != nil
            || ProcessInfo.processInfo.environment["SAFECLEAN_DEMO"] != nil
    #else
        static let hideBanner = false
        static let deviceName: String? = nil
        static let readOnly = false
    #endif
}

// MARK: - 演示视频用的点击目标

/// 录演示视频时记下按钮在窗口里的位置（左上角为原点），合成器据此把鼠标移过去。正式版里什么都不做。
enum DemoTargets {
    nonisolated(unsafe) static var frames: [String: (rect: CGRect, owner: UUID)] = [:]

    static var snapshot: [String: CGRect] { frames.mapValues(\.rect) }
}

extension View {
    func demoTarget(_ id: String) -> some View {
        #if DEBUG
            modifier(DemoTargetModifier(id: id))
        #else
            self
        #endif
    }
}

#if DEBUG
    private struct DemoTargetModifier: ViewModifier {
        let id: String
        @State private var owner = UUID()

        func body(content: Content) -> some View {
            if DebugFlags.readOnly {
                content.background(
                    GeometryReader { geo in
                        let frame = geo.frame(in: .global)
                        Color.clear
                            .onAppear { DemoTargets.frames[id] = (frame, owner) }
                            .onChange(of: frame) { _, f in DemoTargets.frames[id] = (f, owner) }
                            .onDisappear { if DemoTargets.frames[id]?.owner == owner { DemoTargets.frames[id] = nil } }
                    })
            } else {
                content
            }
        }
    }
#endif
