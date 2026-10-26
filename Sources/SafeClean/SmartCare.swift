import AppKit
import SwiftUI

/// 智能呵护：依次跑清理扫描、下载文件夹重复文件、性能分析、应用更新，汇总成一个仪表盘。
/// “运行”只做两件没有副作用的事：清理默认勾选的垃圾、移除重复下载的副本（都进废纸篓）。
@MainActor
final class SmartCareModel: ObservableObject {
    enum Phase { case idle, scanning, ready, running, done }

    @Published var phase: Phase = .idle
    @Published var step = ""
    @Published var stepIndex = 0
    @Published var cleanResult: CleanResult?
    @Published var clutterResult: CleanResult?
    unowned let state: AppState

    static let stepCount = 4

    init(state: AppState) { self.state = state }

    func scan() {
        guard phase != .scanning, phase != .running else { return }
        Task {
            phase = .scanning
            cleanResult = nil
            clutterResult = nil
            stepIndex = 0
            step = "查找系统垃圾"
            await state.junk.runScan()
            stepIndex = 1
            step = "查找下载文件夹里的重复文件"
            await state.clutter.scanDownloadDuplicates()
            stepIndex = 2
            step = "分析性能"
            await state.performance.analyze()
            state.performance.screen = .overview
            stepIndex = 3
            step = "检查应用更新"
            await state.apps.load()
            await state.updates.check(apps: state.apps.apps)
            state.apps.screen = .overview
            stepIndex = 4
            phase = .ready
        }
    }

    var duplicateCount: Int { state.clutter.downloadDuplicates.reduce(0) { $0 + $1.files.filter(\.selected).count } }
    var duplicateSize: Int64 { state.clutter.downloadDuplicates.reduce(0) { $0 + $1.selectedSize } }

    func run() {
        Task {
            phase = .running
            if !state.junk.selected.isEmpty {
                await state.junk.runClean()
                cleanResult = state.junk.result
            }
            if duplicateCount > 0 {
                clutterResult = await state.clutter.trashDownloadDuplicates()
            }
            state.disk.refresh()
            phase = .done
        }
    }
}

struct SmartCareView: View {
    @ObservedObject var model: SmartCareModel
    @ObservedObject var state: AppState
    private let module = Module.smartCare

    var body: some View {
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
                    module: module, title: "正在全面检查…", detail: "第 \(model.stepIndex + 1) / \(SmartCareModel.stepCount) 步：\(model.step)",
                    progress: progress, stop: nil)
            }
        case .running:
            VStack(spacing: 0) {
                StageTopBar(title: module.title)
                ScanningStage(module: module, title: "正在运行…", detail: "清理垃圾、移除重复下载", stop: nil)
            }
        case .ready, .done:
            dashboard
        }
    }

    private var progress: Double {
        let junk = model.stepIndex == 0 ? state.junk.progress : 1
        return (Double(model.stepIndex) + (model.stepIndex == 0 ? junk : 0.5)) / Double(SmartCareModel.stepCount)
    }

    private var dashboard: some View {
        let done = model.phase == .done
        return VStack(spacing: 0) {
            StageTopBar(leadingTitle: "重新开始", leadingAction: { model.phase = .idle }, title: module.title)
            Text(done ? "做得好！你的 Mac 状态良好" : "检查完了，这些可以处理")
                .font(.system(size: 34, weight: .bold))
                .padding(.top, 18)
                .padding(.bottom, 22)
            Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                GridRow {
                    SmartCard(module: .cleanup, title: "清理", value: cleanValue(done: done)) {
                        if done, let r = model.cleanResult, r.trashedCount + r.deletedCount > 0 {
                            DoneChip(text: "已清理")
                        } else if done {
                            DoneChip(text: "没有需要清理的", color: .white.opacity(0.75))
                        } else {
                            StatusText("运行后移到废纸篓")
                        }
                    } open: { state.module = .cleanup }
                    SmartCard(module: .clutter, title: "整理杂乱", value: clutterValue(done: done)) {
                        if done, model.clutterResult != nil {
                            DoneChip(text: "已移除")
                        } else if done || model.duplicateCount == 0 {
                            DoneChip(text: "下载文件夹很整齐", color: .white.opacity(0.75))
                        } else {
                            StatusText("每组保留最早的一份")
                        }
                    } open: { state.module = .clutter }
                }
                GridRow {
                    SmartCard(
                        module: .performance, title: "性能",
                        value: state.performance.heavyCount > 0 ? "\(state.performance.heavyCount) 个高耗能应用" : "运行顺畅"
                    ) {
                        StatusText("内存已用 \(FS.format(state.performance.memoryUsed))，点开看维护任务")
                    } open: { state.module = .performance }
                    SmartCard(
                        module: .applications, title: "应用程序",
                        value: state.updates.updates.isEmpty ? "都是最新版" : "\(state.updates.updates.count) 个可更新"
                    ) {
                        StatusText(state.updates.updates.isEmpty ? "检查了 \(state.updates.checkable) 个应用" : "点开逐个更新")
                    } open: {
                        state.apps.screen = state.updates.updates.isEmpty ? .overview : .updater
                        state.module = .applications
                    }
                }
            }
            .padding(.horizontal, 40)
            .frame(maxHeight: .infinity)
            OrbButton(title: done ? "完成" : "运行", accent: module.accent) {
                if done { model.phase = .idle } else { model.run() }
            }
            .frame(height: 170)
            .padding(.bottom, 18)
        }
        .foregroundStyle(.white)
    }

    private func cleanValue(done: Bool) -> String {
        if done, let r = model.cleanResult { return FS.format(r.trashedBytes + r.deletedBytes) + " 的垃圾" }
        return FS.format(state.junk.selectedSize) + " 的垃圾"
    }

    private func clutterValue(done: Bool) -> String {
        if done, let r = model.clutterResult { return "\(r.trashedCount) 个重复下载" }
        return model.duplicateCount > 0 ? "\(model.duplicateCount) 个重复下载" : "没有重复下载"
    }
}

private struct StatusText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.72))
    }
}

/// 仪表盘里的一张卡片：用对应模块的配色，右上角是模块插画图标。
struct SmartCard<Status: View>: View {
    let module: Module
    let title: String
    let value: String
    @ViewBuilder var status: Status
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [module.colors[1].opacity(0.9), module.colors[2].opacity(0.75)], startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(hovering ? 0.16 : 0.1), .clear], startPoint: .top, endPoint: .bottom))
                Image(systemName: module.heroSymbol)
                    .font(.system(size: 64, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(LinearGradient(colors: [.white, module.accent], startPoint: .top, endPoint: .bottom))
                    .shadow(color: module.accent.opacity(0.8), radius: 18)
                    .padding(22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text(value).font(.system(size: 30, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6).monospacedDigit()
                    status.padding(.top, 6)
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .frame(minHeight: 170, maxHeight: 210)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("打开\(module.title)")
    }
}
