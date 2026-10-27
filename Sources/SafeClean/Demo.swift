#if DEBUG
    import AppKit
    import SwiftUI

    /// Captures every screen the promo video needs as a 3× PNG, plus where each tagged button
    /// sits in the window (`.demoTarget`). Scripts/promo.swift then animates the cursor, clicks,
    /// camera moves and titles at 60 fps from these stills. Everything runs read-only.
    ///
    ///     SAFECLEAN_DEMO=<output folder> SAFECLEAN_ROOT=<folder for Space Lens> SafeClean
    @MainActor
    final class PromoCapture {
        private let dir: URL
        private let window: NSWindow
        private var shots: [[String: Any]] = []
        private var meta: [String: Any] = [:]
        static let scale: CGFloat = 3

        init(dir: URL, window: NSWindow) {
            self.dir = dir
            self.window = window
        }

        func note(_ key: String, _ value: Any) { meta[key] = value }

        /// Waits for SwiftUI transitions to finish, then draws the window into `<name>.png`.
        func shot(_ name: String, settle: Double = 0.7) async {
            try? await Task.sleep(for: .seconds(settle))
            guard let view = window.contentView?.superview ?? window.contentView,
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * Self.scale), pixelsHigh: Int(view.bounds.height * Self.scale),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return }
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            let targets = DemoTargets.snapshot.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }
            shots.append(["name": name, "targets": targets])
        }

        func finish() {
            meta["window"] = [window.contentView?.bounds.width ?? 0, window.contentView?.bounds.height ?? 0]
            meta["scale"] = Self.scale
            meta["lang"] = AppLanguage.current.rawValue
            meta["shots"] = shots
            if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("manifest.json"))
            }
        }
    }

    /// The scripted tour: puts the real views into each state with sample data.
    enum DemoDirector {
        @MainActor static func run(state: AppState, output: URL, lensRoot: URL) async {
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            guard let window = NSApp.windows.first(where: \.isVisible) else {
                NSApp.terminate(nil)
                return
            }
            window.setContentSize(NSSize(width: 1200, height: 750))
            let capture = PromoCapture(dir: output, window: window)
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

            // Smart Care: intro → scanning (progress ring filled frame by frame) → dashboard → done
            state.module = .smartCare
            await capture.shot("care_intro", settle: 1.5)
            let care = state.smartCare
            let steps = [
                L("查找系统垃圾", "Looking for system junk"), L("查找下载文件夹里的重复文件", "Looking for duplicates in Downloads"),
                L("分析性能", "Analyzing performance"), L("检查应用更新", "Checking for app updates"),
            ]
            care.phase = .scanning
            let scanFrames = 24
            capture.note("scanFrames", scanFrames)
            for i in 0..<scanFrames {
                let p = Double(i + 1) / Double(scanFrames)
                care.demoProgress = p
                care.stepIndex = min(3, Int(p * 4 - 0.001))
                care.step = steps[care.stepIndex]
                await capture.shot("care_scan_\(i)", settle: 0.45)
            }
            care.demoProgress = nil
            await DebugStages.prepare(state: state, stage: "ready")
            await capture.shot("care_ready", settle: 1.0)
            care.phase = .running
            await capture.shot("care_running")
            await DebugStages.prepare(state: state, stage: "done")
            await capture.shot("care_done", settle: 1.0)

            // Cleanup: summary → details with the explained, unselected items
            state.junk.loadSample()
            state.module = .cleanup
            await capture.shot("cleanup_summary", settle: 1.0)
            state.junk.showDetails = true
            await capture.shot("cleanup_details", settle: 1.0)
            state.junk.showDetails = false

            // Space Detective: top of the page, then scrolled to the two cards
            await state.detective.loadSample()
            state.module = .detective
            await capture.shot("detective_top", settle: 1.5)
            state.detective.scrollTarget = "cards"
            await capture.shot("detective_cards", settle: 2.0)

            // Space Lens: the map, then one level down into the biggest folder
            state.lens.choose(lensRoot)
            state.lens.scan()
            state.module = .spaceLens
            for _ in 0..<100 where state.lens.screen != .map { await wait(0.1) }
            await capture.shot("lens_root", settle: 1.2)
            if let biggest = state.lens.current?.children.first(where: \.canDrill) {
                capture.note("drill", biggest.name)
                state.lens.current = biggest
                await capture.shot("lens_drill", settle: 1.0)
            }

            // My Clutter and Statistics
            state.module = .clutter
            await DebugStages.prepare(state: state, stage: "overview")
            await capture.shot("clutter", settle: 1.0)
            StatsStore.shared.loadSample()
            state.module = .stats
            await capture.shot("stats", settle: 1.5)

            capture.finish()
            print("演示素材：", output.path)
            NSApp.terminate(nil)
        }
    }
#endif
