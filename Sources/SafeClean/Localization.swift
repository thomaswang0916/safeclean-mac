import AppKit
import SwiftUI

/// Interface language. Chosen in Settings; takes effect after a relaunch so that every screen,
/// scan result and stored label is regenerated in the new language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .english: "English"
        case .chinese: "简体中文"
        }
    }

    static let defaultsKey = "appLanguage"

    /// The language this process is running in (read once at launch).
    static let current: AppLanguage = {
        #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["SAFECLEAN_LANG"], let lang = AppLanguage(rawValue: raw) { return lang }
        #endif
        if let raw = UserDefaults.standard.string(forKey: defaultsKey), let lang = AppLanguage(rawValue: raw) { return lang }
        return .english
    }()

    /// The language saved in settings (may differ from `current` until relaunch).
    static var saved: AppLanguage {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .english }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// Pick the Chinese or English text for the current interface language.
@inline(__always)
func L(_ zh: String, _ en: String) -> String {
    AppLanguage.current == .chinese ? zh : en
}

/// Locale used for dates and numbers, matching the interface language.
var appLocale: Locale { Locale(identifier: AppLanguage.current == .chinese ? "zh_CN" : "en_US") }

// MARK: - Settings window

struct SettingsView: View {
    @State private var language = AppLanguage.saved
    @State private var background = BackgroundRecorder.isEnabled

    var body: some View {
        Form {
            Section {
                Picker(L("界面语言", "Language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: language) { _, value in AppLanguage.saved = value }
                if language != AppLanguage.current {
                    HStack {
                        Text(L("重新启动后生效。", "Restart SafeClean to apply."))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("立即重新启动", "Restart Now")) { Permissions.relaunch() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            Section {
                Toggle(L("后台每 3 小时记录一次空间", "Record disk usage in the background every 3 hours"), isOn: $background)
                    .onChange(of: background) { _, value in BackgroundRecorder.setEnabled(value) }
                Text(
                    L(
                        "供“空间侦探”对比用。低优先级运行，不弹窗、不联网；关掉时会删除对应的启动项。",
                        "Used by Space Detective to compare over time. Runs at low priority, never shows a window or goes online; turning it off removes the launch agent."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text(L("完全磁盘访问权限", "Full Disk Access"))
                    Spacer()
                    Text(Permissions.hasFullDiskAccess() ? L("已开启", "Granted") : L("未开启", "Not granted"))
                        .foregroundStyle(.secondary)
                    Button(L("打开系统设置", "Open System Settings")) { Permissions.openFullDiskAccessSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// English count with the right noun form: plural(1, "item") → "1 item", plural(3, "item") → "3 items".
func plural(_ count: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : (pluralForm ?? singular + "s"))"
}
