#if DEBUG
    import AVFoundation
    import AppKit
    import SwiftUI

    /// Records the app window frame by frame into an MP4. The window is rendered at `scale`,
    /// and a caption band sits below it so captions never cover the UI. Frames are written at a
    /// steady 30 fps; between two renders the previous frame is repeated.
    @MainActor
    final class DemoRecorder {
        private let url: URL
        private let scale: CGFloat
        private var writer: AVAssetWriter?
        private var input: AVAssetWriterInput?
        private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        private var size = CGSize.zero
        private var bandHeight: CGFloat = 0
        private var start: CFTimeInterval = 0
        private var written = 0
        private var rendered = 0
        private var lastBuffer: CVPixelBuffer?
        private var timer: Timer?
        private weak var window: NSWindow?
        var caption = ""
        static let fps = 30.0

        init(url: URL, scale: CGFloat) {
            self.url = url
            self.scale = scale
        }

        func begin(window: NSWindow) throws {
            self.window = window
            guard let view = window.contentView?.superview ?? window.contentView else { return }
            let w = (view.bounds.width * scale / 2).rounded() * 2
            let h = (view.bounds.height * scale / 2).rounded() * 2
            bandHeight = (110 * scale / 2).rounded() * 2
            size = CGSize(width: w, height: h + bandHeight)
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000, AVVideoMaxKeyFrameIntervalKey: 60],
                ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
                ])
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            (self.writer, self.input, self.adaptor) = (writer, input, adaptor)
            start = CACurrentMediaTime()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Self.fps, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer!, forMode: .common)
        }

        func finish() async -> String {
            timer?.invalidate()
            tick()
            input?.markAsFinished()
            await writer?.finishWriting()
            let seconds = CACurrentMediaTime() - start
            return String(format: "%.1f 秒，渲染 %d 帧（%.1f 帧/秒），写入 %d 帧", seconds, rendered, Double(rendered) / seconds, written)
        }

        private func tick() {
            guard let frame = render() else { return }
            lastBuffer = frame
            // 补齐到当前时间：渲染慢的时候重复上一帧，保持 30 帧/秒
            let due = Int((CACurrentMediaTime() - start) * Self.fps)
            while written <= due, let input, input.isReadyForMoreMediaData, let adaptor, let buffer = lastBuffer {
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(Self.fps)))
                written += 1
            }
        }

        private func render() -> CVPixelBuffer? {
            guard let window, let pool = adaptor?.pixelBufferPool, let view = window.contentView?.superview ?? window.contentView
            else { return nil }
            let pixelsWide = Int(size.width), pixelsHigh = Int(size.height - bandHeight)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return nil }
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            rendered += 1
            guard let image = rep.cgImage else { return nil }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            // 字幕栏（底部）+ 窗口画面（上方）
            context.setFillColor(NSColor(calibratedRed: 0.06, green: 0.05, blue: 0.11, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: bandHeight))
            context.draw(image, in: CGRect(x: 0, y: bandHeight, width: size.width, height: size.height - bandHeight))
            drawCaption(in: context)
            return buffer
        }

        private func drawCaption(in context: CGContext) {
            guard !caption.isEmpty else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let text = NSAttributedString(
                string: caption,
                attributes: [.font: NSFont.systemFont(ofSize: 21 * scale, weight: .semibold), .foregroundColor: NSColor.white])
            let textSize = text.size()
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (bandHeight - textSize.height) / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The scripted tour: drives the real views with sample data. Everything runs read-only.
    enum DemoDirector {
        @MainActor static func run(state: AppState, output: URL, lensRoot: URL) async {
            try? await Task.sleep(for: .seconds(1.5))
            let scale = CGFloat(Double(ProcessInfo.processInfo.environment["SAFECLEAN_DEMO_SCALE"] ?? "") ?? 1.5)
            let recorder = DemoRecorder(url: output, scale: scale)
            guard let window = NSApp.windows.first(where: \.isVisible) else {
                NSApp.terminate(nil)
                return
            }
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            /// 先让界面完成切换，再换字幕
            func say(_ text: String) async {
                await wait(0.35)
                recorder.caption = text
            }

            state.module = .smartCare
            await wait(0.8)
            try? recorder.begin(window: window)

            // 1. Smart Care
            await say(L("放心清理：免费开源的 Mac 清理工具", "SafeClean — a free, open-source Mac cleaner"))
            await wait(3)
            await say(L("一次扫描，检查垃圾、重复文件、应用更新和性能", "One scan checks junk, duplicates, updates and performance"))
            let care = state.smartCare
            care.phase = .scanning
            let steps = [L("查找系统垃圾", "Looking for system junk"), L("查找下载文件夹里的重复文件", "Looking for duplicates in Downloads"), L("分析性能", "Analyzing performance"), L("检查应用更新", "Checking for app updates")]
            for (i, step) in steps.enumerated() {
                care.stepIndex = i
                care.step = step
                for p in stride(from: 0.0, through: 1.0, by: 0.1) {
                    if i == 0 { state.junk.progress = p }
                    await wait(0.09)
                }
            }
            await DebugStages.prepare(state: state, stage: "ready")
            care.phase = .ready
            await say(L("找到的东西，都汇总在一个仪表盘里", "Everything it found, on one dashboard"))
            await wait(3.5)
            await say(L("“运行”只清理安全的东西，而且都先进废纸篓", "Run only cleans what's safe — and everything goes to the Trash first"))
            care.run()
            await wait(3.5)

            // 2. Cleanup with explained defaults
            state.junk.loadSample()
            state.module = .cleanup
            await say(L("清理：每一项默认勾选都写明了理由", "Cleanup: every default is explained"))
            await wait(3)
            state.junk.showDetails = true
            await say(L("正在运行的应用和浏览器内核默认不勾", "Caches of running apps and browser engines stay unselected"))
            await wait(4)
            state.junk.showDetails = false

            // 3. Space Detective
            await state.detective.loadSample()
            state.module = .detective
            await say(L("空间侦探：空间去哪了？是谁写的？", "Space Detective: where did my space go — and who wrote it?"))
            await wait(5)
            state.detective.scrollTarget = "cards"
            await say(L("“系统数据”里到底是什么", "What's really inside \"System Data\""))
            await wait(4)
            await say(L("清了马上长回来的缓存会被标出来，不再白清", "Caches that grow right back are flagged — no more pointless cleaning"))
            await wait(4)

            // 4. Space Lens
            state.lens.choose(lensRoot)
            state.lens.scan()
            state.module = .spaceLens
            await say(L("空间透镜：一眼看清空间被谁占了", "Space Lens: see what's taking up space"))
            await wait(3.5)
            if let biggest = state.lens.current?.children.first(where: \.canDrill) {
                state.lens.current = biggest
                await say(L("……还能一层层点进去", "…and drill down folder by folder"))
                await wait(3)
            }

            // 5. Clutter
            await DebugStages.prepare(state: setModule(state, .clutter), stage: "overview")
            await say(L("大文件、重复文件、相似照片和旧下载", "Large files, duplicates, similar photos and old downloads"))
            await wait(3.5)

            // 6. Statistics
            StatsStore.shared.loadSample()
            state.module = .stats
            await say(L("记录清理效果，给出优化建议", "Track what you've cleaned and get recommendations"))
            await wait(3.5)
            await say("github.com/thomaswang0916/safeclean-mac")
            await wait(3.5)

            print("演示视频：", await recorder.finish())
            NSApp.terminate(nil)
        }

        @MainActor private static func setModule(_ state: AppState, _ module: Module) -> AppState {
            state.module = module
            return state
        }
    }
#endif
