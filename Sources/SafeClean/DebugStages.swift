import AppKit
import SwiftUI

#if DEBUG
    /// 截图用：不扫描真实磁盘，填示例数据把各页面摆到指定阶段。
    enum DebugStages {
        @MainActor static func prepare(state: AppState, stage: String) async {
            let env = ProcessInfo.processInfo.environment
            switch (state.module, stage) {
            case (.cleanup, "result"):
                state.junk.loadSample()
            case (.applications, "overview"), (.applications, "uninstaller"), (.applications, "updater"):
                await state.apps.load()
                if let app = state.apps.apps.first {
                    state.updates.updates = [AppUpdate(app: app, installed: app.version, latest: "5.8.0", source: .sparkle, notesURL: nil)]
                }
                state.updates.checkable = 12
                state.apps.screen = stage == "overview" ? .overview : stage == "uninstaller" ? .uninstaller : .updater
                if stage == "uninstaller" { state.apps.selectedID = state.apps.apps.first?.id }
            case (.clutter, _):
                let c = state.clutter
                let d = FS.url("Downloads")
                c.large = [
                    ClutterFile(url: d.appendingPathComponent("Xcode_16.xip"), size: 3_400_000_000, modified: .now.addingTimeInterval(-86400 * 90)),
                    ClutterFile(url: d.appendingPathComponent("会议录屏.mov"), size: 820_000_000, modified: .now.addingTimeInterval(-86400 * 12)),
                ]
                c.duplicates = [
                    FileGroup(files: [
                        ClutterFile(url: d.appendingPathComponent("合同.pdf"), size: 2_400_000, modified: .now.addingTimeInterval(-86400 * 40), note: "保留"),
                        ClutterFile(url: d.appendingPathComponent("合同 (1).pdf"), size: 2_400_000, modified: .now, selected: true),
                    ])
                ]
                c.downloads = [ClutterFile(url: d.appendingPathComponent("installer.dmg"), size: 310_000_000, modified: .now.addingTimeInterval(-86400 * 70))]
                c.screen = stage == "intro" ? .intro : stage == "detail" ? .detail(.duplicates) : .overview
            case (.spaceLens, "map"):
                let root = URL(fileURLWithPath: env["SAFECLEAN_ROOT"] ?? FS.home.path)
                state.lens.choose(root)
                state.lens.scan()
                try? await Task.sleep(for: .seconds(3))
            case (.performance, "overview"), (.performance, "background"), (.performance, "maintenance"):
                await state.performance.analyze()
                state.performance.screen = stage == "overview" ? .overview : stage == "background" ? .background : .maintenance
            case (.smartCare, "ready"), (.smartCare, "done"):
                state.junk.loadSample()
                await state.performance.analyze()
                state.updates.checkable = 12
                let d = FS.url("Downloads")
                state.clutter.downloadDuplicates = [
                    FileGroup(files: [
                        ClutterFile(url: d.appendingPathComponent("a.pdf"), size: 2_400_000, modified: .now, note: "保留"),
                        ClutterFile(url: d.appendingPathComponent("a (1).pdf"), size: 2_400_000, modified: .now, selected: true),
                    ])
                ]
                if stage == "done" {
                    var r = CleanResult()
                    r.trashedCount = 3
                    r.trashedBytes = 152_300_000
                    state.smartCare.cleanResult = r
                    var c = CleanResult()
                    c.trashedCount = 1
                    state.smartCare.clutterResult = c
                }
                state.smartCare.phase = stage == "done" ? .done : .ready
            case (.detective, _):
                await state.detective.loadSample()
            case (.stats, _):
                StatsStore.shared.loadSample()
                state.junk.loadSample()
            default:
                break
            }
        }
    }
#endif
