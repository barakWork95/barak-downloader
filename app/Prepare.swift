// הכנת הורדה: קישור -> פרטי הסרטון -> בחירת איכות/קטע/וואטסאפ -> לתור. וגם מעקב אחרי הלוח.

import AppKit
import SwiftUI

@MainActor
final class Preparer: ObservableObject {
    static let shared = Preparer(queue: .shared, settings: .shared)

    enum Phase: Equatable { case idle, fetching, ready, failed }

    @Published var url = ""
    @Published var phase: Phase = .idle
    @Published var info: VideoInfo?
    @Published var selected = 0
    @Published var trimOn = false
    @Published var trimStart = ""
    @Published var trimEnd = ""
    @Published var whatsapp = false
    @Published var failure: EngineFailure?
    @Published var usedCookies = false
    @Published var pastedFromClipboard = false
    /// יש קישור בלוח, אבל אין הרשאה לקרוא אותו בלי לשאול
    @Published var clipboardHasLink = false
    @Published var isUpdating = false
    @Published var updateStatus: String?

    let queue: DownloadQueue
    let settings: AppSettings
    private var process: Process?
    private var cancelled = false
    private var reloadAfterCancel = false

    init(queue: DownloadQueue, settings: AppSettings) {
        self.queue = queue
        self.settings = settings
    }

    var isBusy: Bool { phase == .fetching }

    // MARK: קריאת הסרטון

    func fetch(withCookies: Bool = false) {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !isBusy else { return }
        phase = .fetching
        failure = nil
        info = nil
        updateStatus = nil
        usedCookies = withCookies
        pastedFromClipboard = false
        clipboardHasLink = false
        cancelled = false
        Task {
            var output = ""
            let args = ["info", link] + (withCookies ? ["--cookies", "chrome"] : [])
            let result = await Engine.launch(args, started: { self.process = $0 }) { output += $0 }
            process = nil
            if cancelled {
                phase = .idle
                if reloadAfterCancel { reloadAfterCancel = false; fetch() }
                return
            }
            let data = Data(output.utf8)
            if let info = try? Engine.decoder.decode(VideoInfo.self, from: data) {
                setReady(info, link: link)
            } else {
                if let failure = try? Engine.decoder.decode(EngineFailure.self, from: data) {
                    self.failure = failure
                } else {
                    failure = EngineFailure(kind: "generic", message: "משהו השתבש בהפעלת מנוע ההורדות.",
                                            detail: result.stderr.isEmpty ? nil : String(result.stderr.suffix(800)))
                }
                phase = .failed
            }
        }
    }

    func setReady(_ info: VideoInfo, link: String) {
        self.info = info
        selected = info.default
        whatsapp = false
        // קישור עם זמן (?t=90) פותח את החיתוך מאותה נקודה
        let start = Fmt.startTime(in: link)
        trimOn = start != nil && canTrim(info)
        trimStart = Fmt.time(start ?? 0) ?? "0:00"
        trimEnd = Fmt.time(info.duration) ?? ""
        phase = .ready
    }

    /// קישור שהגיע מבחוץ (תוסף הכרום, התראה, תפריט): מחליף את מה שמוכן כרגע
    func load(_ link: String) {
        url = link
        if isBusy {
            reloadAfterCancel = true
            cancel()
        } else {
            fetch()
        }
    }

    func cancel() {
        guard isBusy else { return }
        cancelled = true
        process?.terminate()
    }

    func reset() {
        guard !isBusy else { return }
        phase = .idle
        info = nil
        failure = nil
        url = ""
        pastedFromClipboard = false
        updateStatus = nil
    }

    // MARK: חיתוך ווואטסאפ

    func canTrim(_ info: VideoInfo) -> Bool { info.items == 1 && (info.duration ?? 0) > 1 }

    /// הטווח שנבחר, או nil אם החיתוך כבוי. ‏.invalid אם הוא לא תקין.
    enum TrimState { case off, valid(Double, Double), invalid }

    var trim: TrimState {
        guard trimOn, let info, canTrim(info) else { return .off }
        guard let start = Fmt.parseTime(trimStart), let end = Fmt.parseTime(trimEnd),
              start < end, end <= (info.duration ?? .infinity) + 1 else { return .invalid }
        return .valid(start, end)
    }

    var effectiveChoice: Int { whatsapp ? (info?.compact ?? selected) : selected }

    /// הגודל הצפוי של מה שייווצר, אחרי חיתוך/כיווץ
    func estimatedSize(for index: Int) -> Int {
        guard let info, info.choices.indices.contains(index) else { return 0 }
        var duration = info.duration
        var fraction = 1.0
        if case .valid(let start, let end) = trim, let total = info.duration, total > 0 {
            duration = end - start
            fraction = (end - start) / total
        }
        if whatsapp { return WhatsApp.estimatedSize(duration: duration) }
        return Int(Double(info.choices[index].size) * fraction)
    }

    func enqueue() {
        guard let info, phase == .ready else { return }
        if case .invalid = trim { return }
        let index = effectiveChoice
        var range: (Double, Double)?
        var parts = [whatsapp ? "WhatsApp" : info.choices[index].label]
        if case .valid(let start, let end) = trim {
            range = (start, end)
            parts.append("\(Fmt.time(start) ?? "")–\(Fmt.time(end) ?? "")")
        }
        if info.items > 1 { parts.append("\(info.items) סרטונים") }
        queue.add(DownloadJob(url: url.trimmingCharacters(in: .whitespacesAndNewlines), title: info.title,
                              platform: info.platform, thumbnail: info.thumbnail,
                              detail: parts.joined(separator: " · "), state: info.state, choice: index,
                              options: settings.engineOptions(trim: range, whatsapp: whatsapp)))
        reset()
    }

    func updateEngine() {
        isUpdating = true
        updateStatus = nil
        Task {
            struct Result: Decodable { let ok: Bool; let version: String? }
            var output = ""
            _ = await Engine.launch(["update"]) { output += $0 }
            isUpdating = false
            if let result = try? Engine.decoder.decode(Result.self, from: Data(output.utf8)) {
                updateStatus = result.ok ? "yt-dlp מעודכן (גרסה \(result.version ?? "")). נסה שוב."
                    : "העדכון נכשל: \(result.version ?? "")"
            } else {
                updateStatus = "העדכון נכשל."
            }
        }
    }

    // MARK: הלוח

    /// כשהחלון נפתח: אם הועתק קישור, הוא מחכה בשדה (או לפחות מסומן שיש מה להדביק)
    func checkClipboard() {
        guard phase == .idle, url.isEmpty else { return }
        Clipboard.peekLink { link, present in
            guard self.phase == .idle, self.url.isEmpty else { return }
            if let link {
                self.url = link
                self.pastedFromClipboard = true
            } else if self.clipboardHasLink != present {
                self.clipboardHasLink = present
            }
        }
    }
}

/// גישה ללוח בלי להקפיץ את בקשת ההרשאה של macOS: בודקים רק אם יש קישור,
/// וקוראים אותו רק כשהמשתמש אישר "תמיד לאפשר".
@MainActor
enum Clipboard {
    static func peekLink(_ completion: @escaping (_ link: String?, _ present: Bool) -> Void) {
        let board = NSPasteboard.general
        guard #available(macOS 15.4, *) else {
            completion(readLink(), true)
            return
        }
        Task {
            let found = (try? await board.detectedPatterns(for: [\.probableWebURL])) ?? []
            guard !found.isEmpty else { completion(nil, false); return }
            completion(board.accessBehavior == .alwaysAllow ? readLink() : nil, true)
        }
    }

    /// קריאה ישירה. בלי הרשאה, macOS ישאל את המשתמש. רק בתגובה לפעולה שלו.
    static func readLink() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count < 2000, text.hasPrefix("http"), !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }
}

/// במצב סרגל תפריטים: שם לב כשמעתיקים קישור לסרטון ומציע להוריד אותו
@MainActor
final class ClipboardWatcher: ObservableObject {
    static let shared = ClipboardWatcher()

    /// הועתק קישור שעוד לא טופל (מסומן באייקון בסרגל)
    @Published var linkWaiting = false
    private var lastChange = NSPasteboard.general.changeCount
    private var lastOffered: String?
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardWatcher.shared.tick() }
        }
    }

    private func tick() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        if linkWaiting { linkWaiting = false }
        let settings = AppSettings.shared
        // כשהחלון פתוח מולך, אין צורך בהצעה: מדביקים ישירות
        guard settings.menuBar, settings.watchClipboard, !NSApp.isActive else { return }
        Clipboard.peekLink { link, present in
            if let link {
                guard VideoLinks.isVideoLink(link), link != self.lastOffered else { return }
                self.lastOffered = link
                self.linkWaiting = true
                Notifier.linkCopied(link)
            } else if self.linkWaiting != present {
                self.linkWaiting = present
            }
        }
    }

    /// מהתפריט: המשתמש ביקש, אז קוראים את הלוח (macOS עשוי לשאול פעם אחת)
    func downloadCopiedLink() {
        linkWaiting = false
        if let link = Clipboard.readLink() { AppRouter.open(link) } else { AppRouter.showWindow() }
    }
}

/// פתיחת החלון והעברת קישור אליו, מכל מקום (תוסף כרום, התראה, תפריט)
@MainActor
enum AppRouter {
    static var openWindow: (() -> Void)?

    static func showWindow() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        openWindow?()
        NSApp.activate()
    }

    static func open(_ link: String) {
        showWindow()
        Preparer.shared.load(link)
    }
}
