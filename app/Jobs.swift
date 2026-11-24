// תור ההורדות, ההיסטוריה (נשמרת לדיסק), התראות ופס ההתקדמות באייקון ב-Dock.

import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    enum Status: String, Codable { case queued, running, done, failed, cancelled }

    let id: UUID
    let url: String
    let title: String
    let platform: String
    let thumbnail: String?
    /// "1080p" / "WhatsApp · 0:30–0:40"
    let detail: String
    let state: String
    let choice: Int
    let options: String
    let createdAt: Date

    @Published var status: Status
    @Published var fraction = 0.0
    @Published var indeterminate = false
    @Published var speed: Double?
    @Published var eta: Double?
    @Published var stageText: String?
    @Published var itemText: String?
    @Published var paths: [String] = []
    @Published var failure: EngineFailure?
    @Published var finishedAt: Date?

    var task = EngineTask()
    var cancelled: Bool { task.cancelled }

    init(id: UUID = UUID(), url: String, title: String, platform: String, thumbnail: String?, detail: String,
         state: String, choice: Int, options: String, createdAt: Date = Date(), status: Status = .queued) {
        self.id = id
        self.url = url
        self.title = title
        self.platform = platform
        self.thumbnail = thumbnail
        self.detail = detail
        self.state = state
        self.choice = choice
        self.options = options
        self.createdAt = createdAt
        self.status = status
    }

    var isActive: Bool { status == .queued || status == .running }
    var fileExists: Bool { paths.first.map { FileManager.default.fileExists(atPath: $0) } ?? false }

    var record: Record {
        Record(id: id, url: url, title: title, platform: platform, thumbnail: thumbnail, detail: detail,
               state: state, choice: choice, options: options, createdAt: createdAt, status: status,
               paths: paths, failure: failure, finishedAt: finishedAt)
    }

    struct Record: Codable {
        let id: UUID, url: String, title: String, platform: String, thumbnail: String?, detail: String
        let state: String, choice: Int, options: String, createdAt: Date, status: Status
        let paths: [String], failure: EngineFailure?, finishedAt: Date?
    }

    convenience init(record r: Record) {
        self.init(id: r.id, url: r.url, title: r.title, platform: r.platform, thumbnail: r.thumbnail,
                  detail: r.detail, state: r.state, choice: r.choice, options: r.options,
                  createdAt: r.createdAt, status: r.status)
        paths = r.paths
        failure = r.failure
        finishedAt = r.finishedAt
        if r.status == .done { fraction = 1 }
    }
}

@MainActor
final class DownloadQueue: ObservableObject {
    static let shared = DownloadQueue(persist: true)

    /// החדשות למעלה
    @Published private(set) var jobs: [DownloadJob] = []
    private let persist: Bool
    private var lastDockFraction = -1.0

    init(persist: Bool) {
        self.persist = persist
        if persist { load() }
    }

    var running: DownloadJob? { jobs.first { $0.status == .running } }
    var pendingCount: Int { jobs.filter(\.isActive).count }
    var hasFinished: Bool { jobs.contains { !$0.isActive } }

    /// כמה מכל מה שבתור כבר ירד (לאייקון ב-Dock ובסרגל)
    var overallFraction: Double? {
        let active = jobs.filter(\.isActive)
        guard !active.isEmpty else { return nil }
        return active.map { $0.status == .running ? $0.fraction : 0 }.reduce(0, +) / Double(active.count)
    }

    @discardableResult
    func add(_ job: DownloadJob) -> DownloadJob {
        jobs.insert(job, at: 0)
        changed()
        runNext()
        return job
    }

    func cancel(_ job: DownloadJob) {
        switch job.status {
        case .running:
            job.task.cancel()  // ההורדה נעשית בתיקייה זמנית, אז לא נשארים קבצים חלקיים
        case .queued:
            job.status = .cancelled
            changed()
        default:
            break
        }
    }

    func remove(_ job: DownloadJob) {
        if job.isActive { cancel(job) }
        jobs.removeAll { $0.id == job.id }
        changed()
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
        changed()
    }

    /// "נסה שוב": אם המידע שנקרא עדיין שמור, מורידים שוב מיד. אחרת חוזרים לשלב בחירת האיכות.
    func retry(_ job: DownloadJob, prepare: Preparer) {
        if FileManager.default.fileExists(atPath: job.state) {
            remove(job)
            add(DownloadJob(url: job.url, title: job.title, platform: job.platform, thumbnail: job.thumbnail,
                            detail: job.detail, state: job.state, choice: job.choice, options: job.options))
        } else {
            prepare.load(job.url)
        }
    }

    private func runNext() {
        guard running == nil, let next = jobs.last(where: { $0.status == .queued }) else { return }
        run(next)
    }

    private func run(_ job: DownloadJob) {
        job.status = .running
        job.fraction = 0
        job.indeterminate = false
        job.task = EngineTask()
        changed()
        Task {
            var finished = false
            await Engine.download(state: job.state, choice: job.choice, options: job.options, task: job.task) { event in
                handle(event, for: job, finished: &finished)
            }
            if job.cancelled {
                job.status = .cancelled
            } else if !finished {
                job.failure = EngineFailure(kind: "generic", message: "ההורדה נכשלה.")
                job.status = .failed
            }
            if job.finishedAt == nil { job.finishedAt = Date() }
            changed()
            if !job.cancelled { Notifier.downloadFinished(job) }
            runNext()
        }
    }

    private func handle(_ event: EngineEvent, for job: DownloadJob, finished: inout Bool) {
        switch event.type {
        case "progress":
            job.fraction = event.fraction ?? job.fraction
            job.indeterminate = false
            job.speed = event.speed
            job.eta = event.eta
            job.stageText = event.stage == "compress" ? "מכווץ לוואטסאפ…" : nil
            if let item = event.item, let items = event.items, items > 1 {
                job.itemText = "סרטון \(item) מתוך \(items)"
            }
            updateDock()
        case "stage":
            job.indeterminate = true
            switch event.stage {
            case "trimming": job.stageText = "מוריד וחותך את הקטע…"
            default:
                job.stageText = event.audioOnly == true ? "ממיר ל-MP3…"
                    : event.merge == true ? "מחבר וידאו ואודיו…" : "מסיים…"
            }
        case "done":
            finished = true
            job.paths = event.paths ?? []
            job.fraction = 1
            job.indeterminate = false
            job.stageText = nil
            job.finishedAt = Date()
            job.status = .done
        case "error":
            finished = true
            job.failure = EngineFailure(kind: event.kind ?? "generic", message: event.message ?? "ההורדה נכשלה.",
                                        detail: event.detail)
            job.finishedAt = Date()
            job.status = .failed
        default:
            break
        }
    }

    /// משהו השתנה ברשימה: עדכון תצוגה, Dock ושמירה
    private func changed() {
        objectWillChange.send()
        updateDock()
        save()
    }

    private func updateDock() {
        guard persist else { return }
        let fraction = overallFraction
        if let fraction, abs(fraction - lastDockFraction) < 0.01 { return }
        lastDockFraction = fraction ?? -1
        Dock.show(fraction: fraction, pending: pendingCount)
    }

    // MARK: שמירה

    private static var historyURL: URL { AppPaths.history }

    private func save() {
        guard persist else { return }
        let records = jobs.filter { !$0.isActive }.prefix(200).map(\.record)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(records)) else { return }
        try? FileManager.default.createDirectory(at: Self.historyURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.historyURL, options: .atomic)
    }

    private func load() {
        // היסטוריה מהגרסה בשם הקודם
        let old = AppPaths.legacy.appendingPathComponent("history.json")
        if !FileManager.default.fileExists(atPath: Self.historyURL.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: old, to: Self.historyURL)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.historyURL),
              let records = try? decoder.decode([DownloadJob.Record].self, from: data) else { return }
        jobs = records.map(DownloadJob.init(record:))
    }

    /// לצילומי מסך בלבד
    func setForPreview(_ list: [DownloadJob]) { jobs = list }
}

// MARK: - Dock

@MainActor
enum Dock {
    private static let view = DockProgressView()

    static func show(fraction: Double?, pending: Int) {
        let tile = NSApp.dockTile
        if let fraction {
            view.fraction = fraction
            view.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.badgeLabel = pending > 1 ? "\(pending)" : nil
        tile.display()
    }
}

final class DockProgressView: NSView {
    var fraction = 0.0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let bar = NSRect(x: bounds.width * 0.14, y: bounds.height * 0.1, width: bounds.width * 0.72, height: bounds.height * 0.1)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        let inset = bar.insetBy(dx: 3, dy: 3)
        // RTL: הפס מתמלא מימין לשמאל, כמו בחלון
        let width = max(inset.height, inset.width * CGFloat(min(max(fraction, 0), 1)))
        let fill = NSRect(x: inset.maxX - width, y: inset.minY, width: width, height: inset.height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
    }
}

// MARK: - התראות

@MainActor
enum Notifier {
    /// רק באפליקציה האמיתית (לא בבדיקות)
    static var enabled = false

    static func setup() {
        enabled = true
        let center = UNUserNotificationCenter.current()
        center.delegate = NotifierDelegate.shared
        let download = UNNotificationAction(identifier: "download", title: "הורד", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "link", actions: [download], intentIdentifiers: []),
            UNNotificationCategory(identifier: "done", actions: [], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func downloadFinished(_ job: DownloadJob) {
        guard enabled, AppSettings.shared.notify, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = job.status == .done ? "ההורדה הסתיימה" : "ההורדה נכשלה"
        content.body = job.status == .done ? job.title : (job.failure?.message ?? job.title)
        content.sound = .default
        content.categoryIdentifier = "done"
        if let path = job.paths.first { content.userInfo = ["path": path] }
        post(content)
    }

    static func linkCopied(_ link: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "הועתק קישור לסרטון"
        content.body = "ללחוץ כדי להוריד: " + (URL(string: link)?.host ?? link)
        content.categoryIdentifier = "link"
        content.userInfo = ["url": link]
        post(content)
    }

    private static func post(_ content: UNNotificationContent) {
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                     content: content, trigger: nil))
    }
}

final class NotifierDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifierDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let path = info["path"] as? String
        let link = info["url"] as? String
        Task { @MainActor in
            if let path {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else if let link {
                AppRouter.open(link)
            }
        }
        completionHandler()
    }
}
