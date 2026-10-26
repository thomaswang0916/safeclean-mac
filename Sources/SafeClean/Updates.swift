import AppKit
import Foundation

/// 一个有新版本的应用
struct AppUpdate: Identifiable {
    enum Source { case sparkle, appStore }

    let app: AppInfo
    let installed: String
    let latest: String
    let source: Source
    let notesURL: URL?
    var id: URL { app.id }
}

/// 检查更新：用 Sparkle 自动更新的应用读它的 appcast（Info.plist 里的 SUFeedURL），
/// App Store 应用查 iTunes 的公开接口。只读网络，不下载安装任何东西。
enum UpdateChecker {
    static func check(_ app: AppInfo) async -> AppUpdate? {
        guard let info = NSDictionary(contentsOf: app.url.appendingPathComponent("Contents/Info.plist")) else { return nil }
        let short = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? short
        if FS.exists(app.url.appendingPathComponent("Contents/_MASReceipt/receipt")) {
            return await checkAppStore(app, installed: short)
        }
        if let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), feed.scheme == "https" || feed.scheme == "http" {
            return await checkSparkle(app, feed: feed, installedShort: short, installedBuild: build)
        }
        return nil
    }

    static func supportsCheck(_ app: AppInfo) -> Bool {
        if FS.exists(app.url.appendingPathComponent("Contents/_MASReceipt/receipt")) { return true }
        let info = NSDictionary(contentsOf: app.url.appendingPathComponent("Contents/Info.plist"))
        return info?["SUFeedURL"] is String
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    /// 按数字逐段比较版本号，缺的段当 0（9.101 和 9.101.0 视为相同）。
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let comps = v.split(whereSeparator: { !$0.isNumber }).map { Int($0) }
            return comps.isEmpty || comps.contains(nil) ? nil : comps.compactMap { $0 }
        }
        guard var a = parts(candidate), var b = parts(installed) else {
            return candidate.compare(installed, options: .numeric) == .orderedDescending
        }
        let n = max(a.count, b.count)
        a += Array(repeating: 0, count: n - a.count)
        b += Array(repeating: 0, count: n - b.count)
        return a.lexicographicallyPrecedes(b) == false && a != b
    }

    private static func checkSparkle(_ app: AppInfo, feed: URL, installedShort: String, installedBuild: String) async -> AppUpdate? {
        guard let (data, response) = try? await session.data(from: feed),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        let items = AppcastParser.parse(data)
        // 只看正式渠道（没有 sparkle:channel 的条目），取版本号最大的
        guard let newest = items.filter({ $0.channel == nil && !$0.build.isEmpty })
            .max(by: { isNewer($1.build, than: $0.build) })
        else { return nil }
        // Sparkle 用 CFBundleVersion 和 sparkle:version 比较
        guard isNewer(newest.build, than: installedBuild) else { return nil }
        let display = newest.short.isEmpty ? newest.build : newest.short
        // 有的 appcast 内部编号变了但对外版本号没变，这种不算更新
        if !newest.short.isEmpty, !isNewer(newest.short, than: installedShort), !isNewer(installedShort, than: newest.short) { return nil }
        return AppUpdate(app: app, installed: installedShort, latest: display, source: .sparkle, notesURL: newest.notes)
    }

    private static func checkAppStore(_ app: AppInfo, installed: String) async -> AppUpdate? {
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        for country in Set([region, "us"]) {
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [
                URLQueryItem(name: "bundleId", value: app.bundleID), URLQueryItem(name: "country", value: country),
                URLQueryItem(name: "entity", value: "macSoftware"),
            ]
            guard let url = components.url, let (data, _) = try? await session.data(from: url),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let result = (json["results"] as? [[String: Any]])?.first,
                let latest = result["version"] as? String
            else { continue }
            guard isNewer(latest, than: installed) else { return nil }
            let page = (result["trackViewUrl"] as? String).flatMap(URL.init(string:))
            return AppUpdate(app: app, installed: installed, latest: latest, source: .appStore, notesURL: page)
        }
        return nil
    }
}

/// 解析 Sparkle appcast：每个 <item> 的版本号、渠道和更新说明链接。
final class AppcastParser: NSObject, XMLParserDelegate {
    struct Item {
        var short = ""
        var build = ""
        var channel: String?
        var notes: URL?
    }

    private var items: [Item] = []
    private var current: Item?
    private var text = ""

    static func parse(_ data: Data) -> [Item] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        text = ""
        if name == "item" { current = Item() }
        guard current != nil else { return }
        if name == "enclosure" {
            if let v = attributes["sparkle:version"], current!.build.isEmpty { current!.build = v }
            if let v = attributes["sparkle:shortVersionString"], current!.short.isEmpty { current!.short = v }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current != nil else { return }
        switch name {
        case "sparkle:version": if !value.isEmpty { current!.build = value }
        case "sparkle:shortVersionString": if !value.isEmpty { current!.short = value }
        case "sparkle:channel": current!.channel = value
        case "sparkle:releaseNotesLink", "sparkle:fullReleaseNotesLink": current!.notes = current!.notes ?? URL(string: value)
        case "item":
            items.append(current!)
            current = nil
        default: break
        }
    }
}

@MainActor
final class UpdatesModel: ObservableObject {
    @Published var updates: [AppUpdate] = []
    @Published var checking = false
    @Published var checked = 0
    @Published var checkable = 0
    @Published var lastChecked: Date?

    func check(apps: [AppInfo]) async {
        guard !checking else { return }
        checking = true
        checked = 0
        let candidates = await Task.detached { apps.filter(UpdateChecker.supportsCheck) }.value
        checkable = candidates.count
        var found: [AppUpdate] = []
        await withTaskGroup(of: AppUpdate?.self) { group in
            var iterator = candidates.makeIterator()
            for _ in 0..<8 {
                guard let app = iterator.next() else { break }
                group.addTask { await UpdateChecker.check(app) }
            }
            for await result in group {
                checked += 1
                if let result { found.append(result) }
                if let app = iterator.next() { group.addTask { await UpdateChecker.check(app) } }
            }
        }
        updates = found.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        lastChecked = Date()
        checking = false
    }

    func open(_ update: AppUpdate) {
        switch update.source {
        case .appStore:
            NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
        case .sparkle:
            // 打开应用，它自带的 Sparkle 更新器会提示安装新版本
            NSWorkspace.shared.openApplication(at: update.app.url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
