// Turns the stills captured by a debug build (SAFECLEAN_DEMO=<dir>) into a 1080p/60 promo video:
// title cards, a cursor that glides between the real button positions, click ripples,
// camera pushes into the part being talked about, and headlines.
//
//   swiftc -O Scripts/promo.swift -o .build/promo
//   .build/promo <stills dir> <out.mp4> [icon.png] [--size 3840x2160] [--frames 3.5,12,40]
//
// Layout is in 1920×1080 units and scaled to --size (default 4K); --frames writes PNG stills instead.
import AVFoundation
import AppKit

let W = 1920.0, H = 1080.0, FPS = 60.0

// MARK: - Input

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: promo <stills dir> <out.mp4> [icon.png] [--frames t1,t2]")
    exit(1)
}
let dir = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let iconImage: CGImage? = args.count > 3 && !args[3].hasPrefix("--") ? loadImage(URL(fileURLWithPath: args[3])) : nil
let stillTimes: [Double]? = args.firstIndex(of: "--frames").map { args[$0 + 1].split(separator: ",").compactMap { Double($0) } }
let outSize: (w: Int, h: Int) = {
    guard let i = args.firstIndex(of: "--size") else { return (3840, 2160) }
    let parts = args[i + 1].split(separator: "x").compactMap { Int($0) }
    return (parts[0], parts[1])
}()
let pixelScale = Double(outSize.w) / W

func loadImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

struct Shot {
    let url: URL
    let targets: [String: CGRect]

    /// Stills are large (3× the window), so only the few most recently used stay decoded.
    var image: CGImage {
        if let hit = Shot.cache.first(where: { $0.0 == url }) { return hit.1 }
        let img = loadImage(url)!
        Shot.cache.insert((url, img), at: 0)
        if Shot.cache.count > 4 { Shot.cache.removeLast() }
        return img
    }
    nonisolated(unsafe) static var cache: [(URL, CGImage)] = []
}

let manifest = try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) as! [String: Any]
let windowSize: CGSize = {
    let w = manifest["window"] as! [Double]
    return CGSize(width: w[0], height: w[1])
}()
let zh = (manifest["lang"] as? String ?? "").hasPrefix("zh")
func T(_ en: String, _ chinese: String) -> String { zh ? chinese : en }

var shots: [String: Shot] = [:]
for s in manifest["shots"] as! [[String: Any]] {
    let name = s["name"] as! String
    let targets = (s["targets"] as! [String: [Double]]).mapValues { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
    shots[name] = Shot(url: dir.appendingPathComponent(name + ".png"), targets: targets)
}

// MARK: - Easing and tracks

func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
func easeInOut(_ x: Double) -> Double {
    let t = clamp(x)
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}
func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}

/// Keyframes that can interrupt each other: each key starts from wherever the previous one had got to.
struct Track<V> {
    struct Key {
        let t: Double
        let dur: Double
        let v: V
        let ease: (Double) -> Double
    }
    var keys: [Key] = []
    let mix: (V, V, Double) -> V

    mutating func add(_ t: Double, _ v: V, dur: Double = 0, ease: @escaping (Double) -> Double = easeInOut) {
        keys.append(Key(t: t, dur: dur, v: v, ease: ease))
        keys.sort { $0.t < $1.t }
    }

    func at(_ time: Double) -> V {
        func value(from: V, _ k: Key, _ time: Double) -> V {
            k.dur <= 0 ? k.v : mix(from, k.v, k.ease((time - k.t) / k.dur))
        }
        var from = keys[0].v
        var current = keys[0]
        for k in keys.dropFirst() {
            if k.t > time { break }
            from = value(from: from, current, k.t)
            current = k
        }
        return value(from: from, current, time)
    }
}

/// A gentle arc between two points, like a hand moving a mouse.
func arc(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    let cx: Double = (a.x + b.x) / 2 - (b.y - a.y) * 0.12
    let cy: Double = (a.y + b.y) / 2 + (b.x - a.x) * 0.12
    let u: Double = 1 - t
    let x: Double = u * u * a.x + 2 * u * t * cx + t * t * b.x
    let y: Double = u * u * a.y + 2 * u * t * cy + t * t * b.y
    return CGPoint(x: x, y: y)
}

// MARK: - Camera

/// The part of the window (in window points) to show, and where in the frame to show it.
struct Cam {
    var rect: CGRect
    var dest: CGRect

    var scale: Double { min(dest.width / rect.width, dest.height / rect.height) }
    func map(_ p: CGPoint) -> CGPoint {
        CGPoint(x: dest.midX + (p.x - rect.midX) * scale, y: dest.midY + (p.y - rect.midY) * scale)
    }
}

let windowBounds = CGRect(origin: .zero, size: windowSize)
let wideDest: CGRect = {
    let h = 780.0, w = h * windowSize.width / windowSize.height
    return CGRect(x: (W - w) / 2, y: 236, width: w, height: h)
}()
let wide = Cam(rect: windowBounds, dest: wideDest)
let wideScale = wide.scale

/// Push in on a region of the window. Never past 1.6 units per point, so 4K output stays within the 3× stills.
func focus(_ r: CGRect, pad: Double = 40) -> Cam {
    var rect = r.insetBy(dx: -pad, dy: -pad)
    let aspect = W / H
    if rect.width / rect.height < aspect {
        rect = rect.insetBy(dx: -(rect.height * aspect - rect.width) / 2, dy: 0)
    } else {
        rect = rect.insetBy(dx: 0, dy: -(rect.width / aspect - rect.height) / 2)
    }
    let minWidth = W / 1.6
    if rect.width < minWidth {
        rect = rect.insetBy(dx: -(minWidth - rect.width) / 2, dy: -(minWidth / aspect - rect.height) / 2)
    }
    // keep the frame filled with the window rather than the backdrop
    rect.origin.x = min(max(rect.minX, 0), max(windowSize.width - rect.width, 0))
    rect.origin.y = min(max(rect.minY, 0), max(windowSize.height - rect.height, 0))
    return Cam(rect: rect, dest: CGRect(x: 0, y: 0, width: W, height: H))
}

/// A slow push that keeps the headline space clear.
func drift(_ amount: Double) -> Cam {
    Cam(rect: windowBounds.insetBy(dx: windowSize.width * amount, dy: windowSize.height * amount), dest: wideDest)
}

// MARK: - Story

struct UIChange {
    let t: Double
    let shot: String
    let fade: Double
    let scroll: Double  // > 0: scroll the content up by this many points instead of cross-fading
}

struct Headline {
    let t: Double
    let title: String
    let sub: String
}

struct CardLine {
    let text: String
    let size: Double
    let weight: NSFont.Weight
    let color: NSColor
}

struct Card {
    let t0: Double
    let t1: Double
    let lines: [CardLine]
    let icon: Bool
}

struct RGB {
    var r, g, b: Double
}

final class Story {
    var now = 0.0
    var ui: [UIChange] = []
    var headlines: [Headline] = []
    var cards: [Card] = []
    var clicks: [(t: Double, p: CGPoint)] = []
    var cam = Track<Cam>(mix: { a, b, t in Cam(rect: lerp(a.rect, b.rect, t), dest: lerp(a.dest, b.dest, t)) })
    var cursor = Track<CGPoint>(mix: arc)
    var cursorAlpha = Track<Double>(mix: lerp)
    var stage = Track<Double>(mix: lerp)  // background + window visibility
    var glow = Track<RGB> { a, b, t in RGB(r: lerp(a.r, b.r, t), g: lerp(a.g, b.g, t), b: lerp(a.b, b.b, t)) }
    var currentShot = ""
    var cursorAt = CGPoint(x: 900, y: 720)

    init() {
        cam.add(0, wide)
        cursor.add(0, cursorAt)
        cursorAlpha.add(0, 0)
        stage.add(0, 0)
        glow.add(0, RGB(r: 0.6, g: 0.3, b: 0.9))
    }

    func wait(_ s: Double) { now += s }

    func show(_ name: String, fade: Double = 0.4, scroll: Double = 0, at t: Double? = nil) {
        precondition(shots[name] != nil, "missing shot \(name)")
        let t = t ?? now
        ui.append(UIChange(t: t, shot: name, fade: fade, scroll: scroll))
        currentShot = name
        glow.add(t, Self.color(for: name), dur: 0.8)
    }

    func target(_ id: String, in shot: String? = nil) -> CGRect {
        guard let r = shots[shot ?? currentShot]?.targets[id] else { fatalError("no target \(id) in \(shot ?? currentShot)") }
        return r
    }

    func move(to p: CGPoint, dur: Double = 0.9) {
        cursor.add(now, p, dur: dur)
        cursorAt = p
        now += dur
    }

    func move(to id: String, dur: Double = 0.9, dx: Double = 0, dy: Double = 0) {
        let r = target(id)
        move(to: CGPoint(x: r.midX + dx, y: r.midY + dy), dur: dur)
    }

    /// Click where the cursor is; the UI reacts a beat later.
    func click(then shot: String? = nil, fade: Double = 0.35) {
        now += 0.08
        clicks.append((now, cursorAt))
        if let shot { show(shot, fade: fade, at: now + 0.12) }
        now += 0.45
    }

    func camera(_ c: Cam, dur: Double = 1.0) { cam.add(now, c, dur: dur) }

    func headline(_ title: String, _ sub: String) { headlines.append(Headline(t: now, title: title, sub: sub)) }

    func card(_ dur: Double, icon: Bool = false, _ lines: [CardLine]) {
        cards.append(Card(t0: now, t1: now + dur, lines: lines, icon: icon))
        now += dur
    }

    static func color(for shot: String) -> RGB {
        switch shot.split(separator: "_").first ?? "" {
        case "cleanup": RGB(r: 0.15, g: 0.75, b: 0.55)
        case "detective": RGB(r: 0.15, g: 0.55, b: 0.85)
        case "lens": RGB(r: 0.35, g: 0.45, b: 1.0)
        case "clutter": RGB(r: 0.1, g: 0.7, b: 0.75)
        case "stats": RGB(r: 0.45, g: 0.4, b: 0.95)
        default: RGB(r: 0.7, g: 0.3, b: 0.9)
        }
    }
}

let white = NSColor.white
let gray = NSColor(white: 1, alpha: 0.62)
let accent = NSColor(calibratedRed: 0.72, green: 0.6, blue: 1, alpha: 1)
let s = Story()

// Opening
s.wait(0.3)
s.card(2.6, [CardLine(text: T("Your Mac is full. Again.", "Mac 又满了？"), size: 84, weight: .bold, color: white)])
s.wait(0.2)
s.card(
    2.9, icon: true,
    [
        CardLine(text: T("SafeClean", "放心清理"), size: 112, weight: .bold, color: white),
        CardLine(text: T("Free. Open source. Safe by default.", "免费 · 开源 · 默认安全"), size: 38, weight: .medium, color: gray),
    ])

// Smart Care
s.show("care_intro", fade: 0)
s.stage.add(s.now, 1, dur: 1.1, ease: easeOut)
s.headline(T("One click checks everything.", "一键，全面检查。"), T("Junk, duplicate downloads, performance and app updates.", "垃圾、重复下载、性能、应用更新，一次扫完。"))
s.cursorAlpha.add(s.now + 0.6, 1, dur: 0.4)
s.wait(1.5)
s.move(to: "orb", dur: 1.1)
s.click(then: "care_scan_0", fade: 0.25)
s.camera(drift(0.025), dur: 3.4)
s.move(to: CGPoint(x: 1010, y: 690), dur: 1.2)
let scanFrames = manifest["scanFrames"] as? Int ?? 24
let scanStart = s.now - 1.2
for i in 1..<scanFrames { s.show("care_scan_\(i)", fade: 0.14, at: scanStart + Double(i) * 3.0 / Double(scanFrames)) }
s.now = scanStart + 3.3
s.show("care_ready", fade: 0.45)
s.camera(wide, dur: 0.9)
s.headline(T("Everything it found, on one dashboard.", "结果都在一个面板上。"), T("Only what's safe to delete is selected.", "默认只勾选删了会自动重新生成的东西。"))
s.wait(0.6)
s.move(to: "card:cleanup", dur: 1.0, dx: -40, dy: 30)
s.wait(1.1)
s.move(to: "card:clutter", dur: 0.8, dx: -40, dy: 30)
s.wait(0.8)
s.move(to: "orb", dur: 0.9)
s.click(then: "care_running", fade: 0.25)
s.wait(0.7)
s.show("care_done", fade: 0.45)
s.headline(T("Everything goes to the Trash first.", "全部先进废纸篓。"), T("Changed your mind? Put it right back.", "后悔了？随时放回去。"))
s.wait(0.5)
s.camera(focus(s.target("card:cleanup").union(s.target("card:clutter")), pad: 30), dur: 1.0)
s.move(to: "card:cleanup", dur: 0.9, dx: 120, dy: 40)
s.wait(1.9)
s.camera(wide, dur: 0.9)
s.wait(0.5)

// Cleanup
s.move(to: "rail:cleanup", dur: 1.0)
s.click(then: "cleanup_summary")
s.headline(T("Every default, explained.", "每个勾选，都有理由。"), T("What's selected regenerates on its own. The rest is your call.", "勾上的会自动重新生成；其余的有代价，你来决定。"))
s.wait(1.6)
s.move(to: "pill:" + T("Review Details", "查看详情"), dur: 1.0)
s.click(then: "cleanup_details")
s.wait(0.3)
let playwright = s.target("item:ms-playwright")
s.camera(focus(CGRect(x: playwright.minX - 30, y: playwright.minY - 75, width: playwright.width + 40, height: 230), pad: 10), dur: 1.1)
s.move(to: CGPoint(x: playwright.minX + 330, y: playwright.maxY - 4), dur: 1.1)
s.headline(T("Browser engines stay unselected.", "浏览器内核默认不勾。"), T("Re-downloading them takes minutes, so it's up to you.", "删了要重新下载好几分钟，所以留给你决定。"))
s.wait(2.8)
s.camera(wide, dur: 0.9)
s.wait(0.5)

// Space Detective
s.move(to: "rail:detective", dur: 1.0)
s.click(then: "detective_top")
s.headline(T("Lost 29 GB overnight?", "一夜少了 29 GB？"), T("Space Detective shows what grew, and who wrote it.", "空间侦探告诉你：哪里变大了，是谁写进去的。"))
s.wait(1.4)
let change = s.target("det:change")
s.camera(focus(CGRect(x: change.minX, y: change.minY + 120, width: change.width, height: change.height - 120), pad: 16), dur: 1.1)
s.move(to: CGPoint(x: change.midX + 260, y: change.maxY - 70), dur: 1.1)
s.wait(2.4)
s.camera(wide, dur: 0.9)
s.wait(0.9)
let scrolled = s.target("det:change", in: "detective_top").minY - s.target("det:change", in: "detective_cards").minY
s.show("detective_cards", fade: 1.2, scroll: scrolled)
s.headline(T("What's really inside System Data.", "“系统数据”里到底是什么。"), T("Every part explained, with whether it's safe to touch.", "逐项拆开，写明能不能动。"))
s.wait(1.6)
let system = s.target("det:system")
s.camera(focus(CGRect(x: system.minX, y: system.minY, width: system.width, height: 330), pad: 16), dur: 1.0)
s.move(to: CGPoint(x: system.midX + 60, y: system.minY + 170), dur: 1.0)
s.wait(1.8)
let regrowth = s.target("det:regrowth")
s.camera(focus(CGRect(x: regrowth.minX, y: regrowth.minY, width: regrowth.width, height: 220), pad: 16), dur: 1.1)
s.move(to: CGPoint(x: regrowth.midX + 40, y: regrowth.minY + 190), dur: 1.1)
s.headline(T("Pointless cleanups get flagged.", "白清的缓存，直接标出来。"), T("Caches that grow right back stop being selected.", "清完很快长回来的，以后默认不勾。"))
s.wait(2.4)
s.camera(wide, dur: 0.9)
s.wait(0.4)

// Space Lens
s.move(to: "rail:spaceLens", dur: 1.0)
s.click(then: "lens_root")
s.headline(T("See what's taking up space.", "空间被谁占了，一眼看清。"), T("Every folder drawn to scale.", "每个文件夹按大小画成方块。"))
s.wait(1.4)
if let drill = manifest["drill"] as? String, shots["lens_drill"] != nil {
    s.move(to: "tile:" + drill, dur: 1.0)
    s.click(then: "lens_drill")
    s.headline(T("Drill in, folder by folder.", "一层层点进去。"), T("Select anything and move it to the Trash.", "勾选后移到废纸篓。"))
    s.wait(2.2)
}

// My Clutter and Statistics
s.move(to: "rail:clutter", dur: 1.0)
s.click(then: "clutter")
s.headline(T("Clear out the clutter.", "杂乱，一次理清。"), T("Large files, duplicates, similar photos and old downloads.", "大文件、重复文件、相似照片、旧下载。"))
s.wait(2.4)
s.move(to: "rail:stats", dur: 1.0)
s.click(then: "stats")
s.headline(T("Know what you've freed.", "清了多少，都有记录。"), T("Mac health, cleanup history and recommendations.", "Mac 健康度、清理记录和优化建议。"))
s.wait(2.6)

// Closing
s.cursorAlpha.add(s.now, 0, dur: 0.4)
s.stage.add(s.now, 0, dur: 0.9)
s.wait(1.0)
s.card(
    5.2, icon: true,
    [
        CardLine(text: T("SafeClean", "放心清理"), size: 112, weight: .bold, color: white),
        CardLine(text: T("Free and open source · macOS 14 or later", "免费开源 · 支持 macOS 14 及以上"), size: 36, weight: .medium, color: gray),
        CardLine(text: "github.com/thomaswang0916/safeclean-mac", size: 32, weight: .semibold, color: accent),
    ])
s.wait(0.3)
let duration = s.now

// MARK: - Drawing

final class Painter {
    let ctx: CGContext

    init(_ ctx: CGContext) {
        self.ctx = ctx
        // top-left origin, like the window coordinates, in 1920×1080 units
        ctx.translateBy(x: 0, y: Double(outSize.h))
        ctx.scaleBy(x: pixelScale, y: -pixelScale)
        ctx.interpolationQuality = .high
    }

    func image(_ img: CGImage, in r: CGRect, alpha: Double = 1) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    func text(_ string: String, size: Double, weight: NSFont.Weight, color: NSColor, centerX: Double, top: Double, alpha: Double) -> Double {
        let attr = NSAttributedString(
            string: string,
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: zh ? 0 : -size * 0.012])
        let sz = attr.size()
        guard alpha > 0.001 else { return sz.height }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        attr.draw(at: CGPoint(x: centerX - sz.width / 2, y: top))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        return sz.height
    }

    func textWidth(_ string: String, size: Double, weight: NSFont.Weight) -> Double {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).size().width
    }
}

func render(_ t: Double, into ctx: CGContext) {
    let p = Painter(ctx)
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    let stage = s.stage.at(t)
    let cam = s.cam.at(t)
    let zoom = cam.scale / wideScale

    if stage > 0.001 {
        // backdrop: near-black with a soft glow in the module's colour
        ctx.saveGState()
        ctx.setAlpha(stage)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bg = CGGradient(
            colorsSpace: space,
            colors: [CGColor(red: 0.035, green: 0.03, blue: 0.06, alpha: 1), CGColor(red: 0.07, green: 0.055, blue: 0.11, alpha: 1)] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: H), options: [])
        let g = s.glow.at(t)
        let center = cam.map(CGPoint(x: windowSize.width / 2, y: windowSize.height / 2))
        let glow = CGGradient(
            colorsSpace: space, colors: [CGColor(red: g.r, green: g.g, blue: g.b, alpha: 0.42), CGColor(red: g.r, green: g.g, blue: g.b, alpha: 0)] as CFArray,
            locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 1050 * max(1, zoom * 0.8), options: [])
        ctx.restoreGState()

        // the window, rising into place as the stage appears
        let lift = (1 - easeOut(stage)) * 70
        let origin = cam.map(.zero)
        let px = cam.scale
        let frame = CGRect(x: origin.x, y: origin.y + lift, width: windowSize.width * px, height: windowSize.height * px)
        let shape = CGPath(roundedRect: frame, cornerWidth: 12 * px, cornerHeight: 12 * px, transform: nil)
        ctx.saveGState()
        ctx.setAlpha(stage)
        ctx.setShadow(offset: CGSize(width: 0, height: 30 * px), blur: 80 * px, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.7))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(red: 0.1, green: 0.08, blue: 0.15, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        drawUI(t, p, frame: frame, px: px, alpha: stage)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setAlpha(stage)
        ctx.addPath(shape)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()

        drawClicks(t, cam: cam, lift: lift)
        drawCursor(t, cam: cam, lift: lift, alpha: s.cursorAlpha.at(t) * stage)
        drawHeadline(t, p, zoom: zoom, alpha: stage)
    }
    drawCards(t, p)
}

func drawUI(_ t: Double, _ p: Painter, frame: CGRect, px: Double, alpha: Double) {
    guard let i = s.ui.lastIndex(where: { $0.t <= t }) else { return }
    let change = s.ui[i]
    let current = shots[change.shot]!.image
    let age = t - change.t
    guard i > 0, age < change.fade else {
        p.image(current, in: frame, alpha: alpha)
        return
    }
    let previous = shots[s.ui[i - 1].shot]!.image
    if change.scroll > 0 {
        // scroll the page content (right of the icon rail) instead of cross-fading
        let e = easeInOut(age / change.fade)
        let rail = 88 * px
        p.image(current, in: frame, alpha: alpha)
        let content = CGRect(x: frame.minX + rail, y: frame.minY, width: frame.width - rail, height: frame.height)
        p.ctx.saveGState()
        p.ctx.clip(to: content)
        p.image(current, in: frame.offsetBy(dx: 0, dy: change.scroll * (1 - e) * px), alpha: alpha)
        p.ctx.clip(to: CGRect(x: content.minX, y: content.minY, width: content.width, height: content.height - change.scroll * e * px))
        p.image(previous, in: frame.offsetBy(dx: 0, dy: -change.scroll * e * px), alpha: alpha)
        p.ctx.restoreGState()
    } else {
        p.image(previous, in: frame, alpha: alpha)
        p.image(current, in: frame, alpha: alpha * easeInOut(age / change.fade))
    }
}

func drawClicks(_ t: Double, cam: Cam, lift: Double) {
    guard let ctx = currentContext else { return }
    for click in s.clicks where t >= click.t && t < click.t + 0.7 {
        let age = (t - click.t) / 0.7
        let c = cam.map(click.p)
        let r = (10 + 46 * easeOut(age)) * cam.scale
        let a = 0.7 * (1 - age)
        let ring = CGRect(x: c.x - r, y: c.y + lift - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: a * 0.28))
        ctx.fillEllipse(in: ring)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: a))
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: ring)
        ctx.restoreGState()
    }
}

nonisolated(unsafe) var currentContext: CGContext?

/// The macOS arrow pointer, tip at (0, 0), in points.
let arrow: CGPath = {
    let path = CGMutablePath()
    path.addLines(between: [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.6), CGPoint(x: 4.0, y: 12.8), CGPoint(x: 6.7, y: 18.9), CGPoint(x: 9.4, y: 17.8),
        CGPoint(x: 6.8, y: 11.9), CGPoint(x: 12.2, y: 11.9),
    ])
    path.closeSubpath()
    return path
}()

func drawCursor(_ t: Double, cam: Cam, lift: Double, alpha: Double) {
    guard alpha > 0.001, let ctx = currentContext else { return }
    let pos = cam.map(s.cursor.at(t))
    var press = 1.0
    for click in s.clicks where t >= click.t - 0.08 && t < click.t + 0.25 {
        let d = t - click.t
        press = d < 0 ? 1 - 0.2 * (d + 0.08) / 0.08 : 0.8 + 0.2 * easeOut(d / 0.25)
    }
    let unit = 1.6 * cam.scale * press
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: pos.x, y: pos.y + lift)
    ctx.scaleBy(x: unit, y: unit)
    ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
    ctx.addPath(arrow)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(1.5)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()
}

func drawHeadline(_ t: Double, _ p: Painter, zoom: Double, alpha: Double) {
    guard let i = s.headlines.lastIndex(where: { $0.t <= t }) else { return }
    let topStyle = clamp((1.16 - zoom) / 0.1)
    let pillStyle = clamp((zoom - 1.1) / 0.12)

    func draw(_ h: Headline, fade: Double, dy: Double) {
        let a = fade * alpha
        guard a > 0.001 else { return }
        if topStyle > 0 {
            _ = p.text(h.title, size: 58, weight: .bold, color: white, centerX: W / 2, top: 64 + dy, alpha: a * topStyle)
            _ = p.text(h.sub, size: 27, weight: .regular, color: gray, centerX: W / 2, top: 146 + dy, alpha: a * topStyle)
        }
        if pillStyle > 0 {
            let width = max(p.textWidth(h.title, size: 34, weight: .bold), p.textWidth(h.sub, size: 22, weight: .regular)) + 72
            let box = CGRect(x: (W - width) / 2, y: H - 168 + dy, width: width, height: 118)
            let path = CGPath(roundedRect: box, cornerWidth: 26, cornerHeight: 26, transform: nil)
            p.ctx.saveGState()
            p.ctx.setAlpha(a * pillStyle)
            p.ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
            p.ctx.addPath(path)
            p.ctx.setFillColor(CGColor(red: 0.06, green: 0.05, blue: 0.1, alpha: 0.82))
            p.ctx.fillPath()
            p.ctx.restoreGState()
            p.ctx.saveGState()
            p.ctx.setAlpha(a * pillStyle)
            p.ctx.addPath(path)
            p.ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
            p.ctx.strokePath()
            p.ctx.restoreGState()
            _ = p.text(h.title, size: 34, weight: .bold, color: white, centerX: W / 2, top: box.minY + 18, alpha: a * pillStyle)
            _ = p.text(h.sub, size: 22, weight: .regular, color: gray, centerX: W / 2, top: box.minY + 68, alpha: a * pillStyle)
        }
    }

    let age = t - s.headlines[i].t
    if i > 0, age < 0.3 {
        draw(s.headlines[i - 1], fade: 1 - age / 0.3, dy: -10 * age / 0.3)
    }
    let inT = easeOut((age - 0.15) / 0.6)
    draw(s.headlines[i], fade: inT, dy: 18 * (1 - inT))
}

func drawCards(_ t: Double, _ p: Painter) {
    for card in s.cards where t >= card.t0 && t <= card.t1 {
        let out = 1 - clamp((t - (card.t1 - 0.5)) / 0.5)
        let iconSize = card.icon && iconImage != nil ? 168.0 : 0
        let heights = card.lines.map { $0.size * 1.25 }
        let total = iconSize + (iconSize > 0 ? 34 : 0) + heights.reduce(0, +) + Double(card.lines.count - 1) * 14
        var y = (H - total) / 2
        if let iconImage, iconSize > 0 {
            let a = easeOut((t - card.t0) / 0.8) * out
            let grow = 0.92 + 0.08 * a
            let size = iconSize * grow
            p.image(iconImage, in: CGRect(x: (W - size) / 2, y: y + (iconSize - size) / 2, width: size, height: size), alpha: a)
            y += iconSize + 34
        }
        for (n, line) in card.lines.enumerated() {
            let appear = card.t0 + (iconSize > 0 ? 0.25 : 0) + 0.3 * Double(n)
            let a = easeOut((t - appear) / 0.8) * out
            _ = p.text(line.text, size: line.size, weight: line.weight, color: line.color, centerX: W / 2, top: y + 26 * (1 - a), alpha: a)
            y += heights[n] + 14
        }
    }
}

// MARK: - Output

func makeContext(data: UnsafeMutableRawPointer?, bytesPerRow: Int) -> CGContext {
    CGContext(
        data: data, width: outSize.w, height: outSize.h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}

if let stillTimes {
    for t in stillTimes {
        let ctx = makeContext(data: nil, bytesPerRow: 0)
        currentContext = ctx
        render(t, into: ctx)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let url = output.deletingPathExtension().appendingPathExtension(String(format: "%05.1f.png", t))
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        print(url.path)
    }
    exit(0)
}

try? FileManager.default.removeItem(at: output)
let writer = try! AVAssetWriter(outputURL: output, fileType: .mp4)
let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: outSize.w, AVVideoHeightKey: outSize.h,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: Int(14_000_000 * pixelScale * pixelScale * 0.7), AVVideoMaxKeyFrameIntervalKey: 120, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
    ])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: outSize.w,
        kCVPixelBufferHeightKey as String: outSize.h,
    ])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let frameCount = Int(duration * FPS)
let started = Date()
for f in 0..<frameCount {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let buffer else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = makeContext(data: CVPixelBufferGetBaseAddress(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
    currentContext = ctx
    autoreleasepool { render(Double(f) / FPS, into: ctx) }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(FPS)))
    if f % 600 == 0 { print("frame \(f)/\(frameCount)") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(String(format: "%@: %.1f s, %d frames, rendered in %.0f s", output.lastPathComponent, duration, frameCount, Date().timeIntervalSince(started)))
