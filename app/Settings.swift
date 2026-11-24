// הגדרות (נשמרות ב-UserDefaults) ומסך ההגדרות.

import AppKit
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var outDir: String { didSet { save(outDir, "outDir") } }
    @Published var byPlatform: Bool { didSet { save(byPlatform, "byPlatform") } }
    @Published var nameStyle: String { didSet { save(nameStyle, "nameStyle") } }
    @Published var sponsorBlock: Bool { didSet { save(sponsorBlock, "sponsorBlock") } }
    @Published var notify: Bool { didSet { save(notify, "notify") } }
    @Published var menuBar: Bool { didSet { save(menuBar, "menuBar") } }
    @Published var watchClipboard: Bool { didSet { save(watchClipboard, "watchClipboard") } }

    /// בבדיקות: לא קוראים ולא כותבים הגדרות אמיתיות
    private let persist: Bool

    init(persist: Bool = true) {
        self.persist = persist
        let d = UserDefaults.standard
        Self.migrateFromOldName(persist: persist)
        func bool(_ key: String, _ fallback: Bool) -> Bool { persist ? (d.object(forKey: key) as? Bool ?? fallback) : fallback }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        // YTDL_DIR (משתנה סביבה) גובר, בשביל בדיקות
        outDir = ProcessInfo.processInfo.environment["YTDL_DIR"] ?? (persist ? d.string(forKey: "outDir") : nil) ?? downloads
        byPlatform = bool("byPlatform", false)
        nameStyle = (persist ? d.string(forKey: "nameStyle") : nil) ?? "title_quality"
        sponsorBlock = bool("sponsorBlock", false)
        notify = bool("notify", true)
        menuBar = bool("menuBar", false)
        watchClipboard = bool("watchClipboard", true)
    }

    /// ההגדרות מהגרסה שנקראה "מוריד סרטונים" (מזהה אחר, ולכן מקום שמירה אחר)
    private static func migrateFromOldName(persist: Bool) {
        let d = UserDefaults.standard
        guard persist, !d.bool(forKey: "migratedFromVideoDownloader") else { return }
        if let old = UserDefaults(suiteName: "local.claude.video-downloader") {
            for key in ["outDir", "byPlatform", "nameStyle", "sponsorBlock", "notify", "menuBar", "watchClipboard"] {
                if let value = old.object(forKey: key) { d.set(value, forKey: key) }
            }
        }
        d.set(true, forKey: "migratedFromVideoDownloader")
    }

    private func save(_ value: Any, _ key: String) {
        if persist { defaults.set(value, forKey: key) }
    }

    var outURL: URL { URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath) }

    func engineOptions(trim: (Double, Double)?, whatsapp: Bool) -> String {
        var options: [String: Any] = [
            "out_dir": outURL.path,
            "by_platform": byPlatform,
            "name_style": nameStyle,
            "sponsorblock": sponsorBlock,
            "whatsapp": whatsapp,
        ]
        if let trim { options["trim"] = [trim.0, trim.1] }
        return JSONText.from(options)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outURL
        panel.prompt = "בחר"
        if panel.runModal() == .OK, let url = panel.url { outDir = url.path }
    }

    /// מעתיק את תוסף הכרום למקום קבוע (מתוך חבילת האפליקציה כרום לא יכול לבחור אותו)
    @discardableResult
    static func installChromeExtension() -> URL {
        let target = AppPaths.chromeExtension
        guard let source = Bundle.main.url(forResource: "chrome-extension", withExtension: nil) else { return target }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: source, to: target)
        return target
    }

    /// אם התוסף כבר הותקן, מרעננים את הקבצים שלו (למשל אחרי עדכון של האפליקציה)
    static func refreshInstalledChromeExtension() {
        if FileManager.default.fileExists(atPath: AppPaths.chromeExtension.path) { installChromeExtension() }
    }

    func revealChromeExtension() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.installChromeExtension()])
    }

    var clipboardAlwaysAllowed: Bool {
        if #available(macOS 15.4, *) { return NSPasteboard.general.accessBehavior == .alwaysAllow }
        return true
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var folderName: String {
        (settings.outDir as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Form {
            Section("שמירה") {
                LabeledContent("תיקייה") {
                    HStack(spacing: 8) {
                        Text(folderName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("שינוי…") { settings.chooseFolder() }
                    }
                }
                Toggle("תיקייה נפרדת לכל פלטפורמה", isOn: $settings.byPlatform)
                Picker("שם הקובץ", selection: $settings.nameStyle) {
                    Text("כותרת (איכות)").tag("title_quality")
                    Text("כותרת בלבד").tag("title")
                    Text("ערוץ - כותרת (איכות)").tag("uploader_title")
                }
            }
            Section {
                Toggle("דילוג על קטעי חסות ופרסום ביוטיוב", isOn: $settings.sponsorBlock)
            } header: {
                Text("הורדה")
            } footer: {
                Text("לפי SponsorBlock, מאגר קהילתי שמסמן קטעים כאלה. הקטעים נחתכים מהקובץ.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("אייקון בסרגל התפריטים, והאפליקציה ממשיכה לפעול כשסוגרים את החלון", isOn: $settings.menuBar)
                Toggle("הצעה להוריד כשמעתיקים קישור לסרטון", isOn: $settings.watchClipboard)
                    .disabled(!settings.menuBar)
            } header: {
                Text("סרגל התפריטים")
            } footer: {
                if settings.menuBar && settings.watchClipboard && !settings.clipboardAlwaysAllowed {
                    Text("כדי שההצעה תופיע לבד, macOS צריך לאפשר לאפליקציה לקרוא את הלוח: הגדרות המערכת ← פרטיות ואבטחה ← הדבקה מאפליקציות אחרות ← 'אפשר'. בלי זה, האייקון בסרגל רק יסמן שהועתק קישור.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            EngineSection(tools: .shared)
            Section("התראות") {
                Toggle("התראה כשהורדה מסתיימת (כשהאפליקציה ברקע)", isOn: $settings.notify)
            }
            Section {
                Button("הצג את התוסף ב-Finder") { settings.revealChromeExtension() }
            } header: {
                Text("תוסף לכרום")
            } footer: {
                Text("בכרום: פתח את chrome://extensions, הפעל 'מצב מפתח' (Developer mode), וגרור את התיקייה שנפתחה לתוך הדף. מעכשיו כפתור התוסף, או קליק ימני על סרטון או קישור, שולח אותו לכאן.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

struct EngineSection: View {
    @ObservedObject var tools: ToolManager
    var body: some View {
        Section {
            LabeledContent("yt-dlp") {
                HStack(spacing: 8) {
                    Text(tools.ytdlpVersion.isEmpty ? "לא מותקן" : tools.ytdlpVersion).foregroundStyle(.secondary).monospacedDigit()
                    Button(tools.isUpdating ? "בודק…" : "בדוק עדכון") { tools.checkForUpdate() }
                        .disabled(tools.isUpdating || tools.phase != .ready)
                }
            }
        } header: {
            Text("מנוע ההורדות")
        } footer: {
            Text(tools.updateMessage ?? "מתעדכן לבד פעם ביום, כי אתרי הוידאו משתנים כל הזמן.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
