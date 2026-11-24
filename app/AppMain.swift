// Barak ⚡ Downloader: ממשק Mac מעל engine.py (yt-dlp + ffmpeg).
// בנייה: ../build.sh  |  בדיקות: --snapshot <תיקייה>, --selftest <קישור> <איכות> [cancel|whatsapp|trim=30-40|queue2]

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        registerURLHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerURLHandler()  // שוב, למקרה ש-SwiftUI רשם handler משלו בדרך
        Notifier.setup()
        ClipboardWatcher.shared.start()
        Task { await ToolManager.shared.ensureReady() }
        UpdateChecker.shared.checkIfDue()
        AppSettings.refreshInstalledChromeExtension()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix("main") == true else { return }
            MainActor.assumeIsolated {
                // במצב סרגל תפריטים האפליקציה נשארת ברקע, בלי אייקון ב-Dock (אלא אם יש הורדות)
                if AppSettings.shared.menuBar && DownloadQueue.shared.pendingCount == 0 {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    /// barak://add?url=<קישור>  (מתוסף הכרום)
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let link = URLComponents(string: raw)?.queryItems?.first(where: { $0.name == "url" })?.value,
              link.hasPrefix("http") else { return }
        MainActor.assumeIsolated { AppRouter.open(link) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !AppSettings.shared.menuBar }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let pending = DownloadQueue.shared.pendingCount
            guard pending > 0 else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = pending == 1 ? "יש הורדה בתהליך" : "יש \(pending) הורדות בתהליך"
            alert.informativeText = "אם תצא עכשיו, הן יבוטלו."
            alert.addButton(withTitle: "המשך להוריד")
            alert.addButton(withTitle: "צא בכל זאת")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Preparer.shared.cancel()
            DownloadQueue.shared.jobs.filter(\.isActive).forEach { DownloadQueue.shared.cancel($0) }
        }
    }

    /// לחיצה על האייקון ב-Dock כשהחלון סגור
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppRouter.showWindow() } }
        return true
    }
}

struct MainWindow: View {
    @ObservedObject var prep: Preparer
    @ObservedObject var queue: DownloadQueue
    @ObservedObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(prep: prep, queue: queue, settings: settings)
            .onAppear {
                AppRouter.openWindow = { openWindow(id: "main") }
                prep.checkClipboard()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                prep.checkClipboard()
            }
    }
}

struct BarakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // רק ההגדרות, בשביל הופעת האייקון בסרגל. אסור שהסצנות יצפו במודלים שמשתנים כל הזמן
    // (קישור בלוח, התקדמות): כל שינוי כזה בונה מחדש את כל החלונות, ובזמן ההפעלה זה נכנס
    // ללולאה אין-סופית שהפילה את האפליקציה.
    @ObservedObject private var settings = AppSettings.shared

    /// SwiftUI כותב לכאן false כשהמערכת מסתירה את האייקון בסרגל. מתעלמים: ההגדרה של המשתמש קובעת,
    /// וכל כתיבה הייתה מפעילה בנייה מחדש של כל הסצנות.
    private var menuBarInserted: Binding<Bool> {
        Binding(get: { AppSettings.shared.menuBar }, set: { _ in })
    }

    var body: some Scene {
        Window(AppPaths.name, id: "main") {
            MainWindow(prep: .shared, queue: .shared, settings: .shared)
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings {
            SettingsView(settings: .shared)
        }

        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarPanel(queue: .shared, watcher: .shared)
        } label: {
            MenuBarIcon(queue: .shared, watcher: .shared)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var queue: DownloadQueue
    @ObservedObject var watcher: ClipboardWatcher
    var body: some View {
        Image(systemName: queue.running != nil ? "bolt.circle.fill"
              : watcher.linkWaiting ? "link.circle.fill" : "bolt.circle")
    }
}

// MARK: - צילומי מצבים (לבדיקה)

@MainActor
enum Snapshots {
    static let sample = VideoInfo(
        state: "", title: "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film",
        uploader: "Blender", platform: "YouTube",
        thumbnail: "https://i.ytimg.com/vi/aqz-KE-bpKQ/hqdefault.jpg", duration: 635, items: 1,
        choices: [
            Choice(label: "2160p", size: 1_373_000_000, note: "לא נפתח ב-QuickTime, כן ב-VLC/IINA", audioOnly: false),
            Choice(label: "1440p", size: 484_000_000, note: "לא נפתח ב-QuickTime, כן ב-VLC/IINA", audioOnly: false),
            Choice(label: "1080p", size: 268_000_000, note: "", audioOnly: false),
            Choice(label: "720p", size: 161_000_000, note: "", audioOnly: false),
            Choice(label: "480p", size: 38_000_000, note: "", audioOnly: false),
            Choice(label: "אודיו בלבד (MP3)", size: 19_000_000, note: "", audioOnly: true),
        ],
        default: 2, compact: 3)

    static func sampleJobs() -> [DownloadJob] {
        let running = DownloadJob(url: "https://youtu.be/aqz-KE-bpKQ", title: sample.title, platform: "YouTube",
                                  thumbnail: sample.thumbnail, detail: "1080p", state: "", choice: 2, options: "{}",
                                  status: .running)
        running.fraction = 0.42; running.speed = 8_100_000; running.eta = 14
        let queued = DownloadJob(url: "https://www.instagram.com/reel/CDUMkliABpa/", title: "Video by clippedinandfree",
                                 platform: "Instagram", thumbnail: nil, detail: "WhatsApp", state: "", choice: 0,
                                 options: "{}", status: .queued)
        let done = DownloadJob(url: "https://x.com/historyinmemes/status/1790637656616943991",
                               title: "Historic Vids - One of the most intense moments in history", platform: "X",
                               thumbnail: nil, detail: "720p · 0:05–0:12", state: "", choice: 0, options: "{}",
                               status: .done)
        done.paths = ["/tmp"]; done.finishedAt = Date()
        let failed = DownloadJob(url: "https://www.tiktok.com/@x/video/1", title: "TikTok video #6748451240264420610",
                                 platform: "TikTok", thumbnail: nil, detail: "576p", state: "", choice: 0,
                                 options: "{}", status: .failed)
        failed.failure = EngineFailure(kind: "blocked", message: "האתר חוסם את ההורדה של הפוסט הזה מהרשת שלך.")
        return [queued, running, done, failed]
    }

    /// חלון שיכול להיות "פעיל", כדי שהכפתורים יצוירו בצבע (לצילומים לאתר)
    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    static func render(to dir: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate()
        let settings = AppSettings(persist: false)
        let readyTools = ToolManager()
        readyTools.phase = .ready
        let installing = ToolManager()
        installing.phase = .installing
        installing.fraction = 0.42
        installing.current = "deno"
        write(ContentView(prep: Preparer(queue: DownloadQueue(persist: false), settings: settings),
                          queue: DownloadQueue(persist: false), settings: settings, tools: installing),
              "0-setup-light", dir: dir, dark: false, wait: 0.4)
        typealias Setup = (Preparer, DownloadQueue) -> Void
        let states: [(String, Setup)] = [
            ("1-idle", { _, _ in }),
            ("2-clipboard", { p, _ in p.clipboardHasLink = true }),
            ("3-fetching", { p, _ in p.url = "https://youtu.be/aqz-KE-bpKQ"; p.phase = .fetching }),
            ("4-ready", { p, _ in p.url = "https://youtu.be/aqz-KE-bpKQ"; p.setReady(sample, link: p.url) }),
            ("5-trim-whatsapp", { p, q in
                p.url = "https://youtu.be/aqz-KE-bpKQ?t=30"; p.setReady(sample, link: p.url)
                p.trimEnd = "0:45"; p.whatsapp = true; q.setForPreview(sampleJobs())
            }),
            ("6-queue", { _, q in q.setForPreview(sampleJobs()) }),
            ("7-failed", { p, _ in
                p.url = "https://www.instagram.com/reel/xyz/"
                p.failure = EngineFailure(kind: "login",
                                          message: "הסרטון דורש התחברות: הוא פרטי, מוגבל גיל, או שהאתר לא מציג אותו בלי חשבון.",
                                          detail: "ERROR: [Instagram] xyz: login required")
                p.phase = .failed
            }),
        ]
        for (name, setup) in states {
            for dark in [false, true] {
                let queue = DownloadQueue(persist: false)
                let prep = Preparer(queue: queue, settings: settings)
                setup(prep, queue)
                write(ContentView(prep: prep, queue: queue, settings: settings, tools: readyTools), "\(name)-\(dark ? "dark" : "light")",
                      dir: dir, dark: dark, wait: name.hasPrefix("4") || name.hasPrefix("5") ? 2.5 : 0.4)
            }
        }
        write(SettingsView(settings: settings), "8-settings-light", dir: dir, dark: false, wait: 0.4)
        let queue = DownloadQueue(persist: false)
        queue.setForPreview(sampleJobs())
        let watcher = ClipboardWatcher()
        watcher.linkWaiting = true
        write(MenuBarPanel(queue: queue, watcher: watcher).background(Color(nsColor: .windowBackgroundColor)),
              "9-menubar-dark", dir: dir, dark: true, wait: 0.4)
    }

    static func write<V: View>(_ view: V, _ name: String, dir: String, dark: Bool, wait: Double) {
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let window = KeyWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        window.setFrame(NSRect(x: -20_000, y: -20_000, width: host.fittingSize.width, height: host.fittingSize.height), display: false)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(wait))  // זמן לתמונות הממוזערות
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        // SNAPSHOT_SCALE=2: חד במסכי Retina (בשביל האתר)
        let scale = Double(ProcessInfo.processInfo.environment["SNAPSHOT_SCALE"] ?? "") ?? 1
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * scale),
                                         pixelsHigh: Int(host.bounds.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}

// MARK: - בדיקה מקצה לקצה (אותו קוד שהממשק מפעיל)

@MainActor
enum SelfTest {
    static func spin(timeout: Double, until done: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    static func run(url: String, choice: Int, flags: [String]) {
        _ = NSApplication.shared
        let tools = ToolManager.shared
        let started = Date()
        Task { await tools.ensureReady() }
        spin(timeout: 900) { tools.phase == .ready || { if case .failed = tools.phase { return true }; return false }() }
        print("tools:", tools.phase, String(format: "%.0fs", Date().timeIntervalSince(started)), "| yt-dlp", tools.ytdlpVersion,
              "|", tools.ytdlp, "|", tools.deno, "|", tools.ffmpeg)
        guard tools.phase == .ready else { return }
        let queue = DownloadQueue(persist: false)
        let prep = Preparer(queue: queue, settings: AppSettings(persist: false))
        prep.url = url
        prep.fetch()
        spin(timeout: 180) { !prep.isBusy }
        print("fetch:", prep.phase, "|", prep.info?.platform ?? "", "|", prep.info?.title ?? "",
              "|", prep.info?.choices.map(\.label) ?? [], "| default", prep.info?.default ?? -1,
              "compact", prep.info?.compact ?? -1, "|", prep.failure?.message ?? "")
        guard prep.phase == .ready else { return }

        prep.selected = choice
        prep.whatsapp = flags.contains("whatsapp")
        if let trim = flags.first(where: { $0.hasPrefix("trim=") })?.dropFirst(5).split(separator: "-"), trim.count == 2 {
            prep.trimOn = true
            prep.trimStart = String(trim[0])
            prep.trimEnd = String(trim[1])
        }
        print("estimate:", Fmt.size(prep.estimatedSize(for: prep.effectiveChoice)), "| trim", prep.trim)
        let info = prep.info!
        prep.enqueue()
        print("after enqueue: prep", prep.phase, "| jobs", queue.jobs.map { "\($0.detail):\($0.status)" })
        if flags.contains("queue2") {  // עוד אחת לתור: צריכה לחכות עד שהראשונה תסתיים
            prep.url = url
            prep.setReady(info, link: url)
            prep.selected = min(choice + 1, info.choices.count - 1)
            prep.enqueue()
            print("queued second:", queue.jobs.map { "\($0.detail):\($0.status)" })
        }

        var maxFraction = 0.0
        var stages = Set<String>()
        var sawOrder = Set<String>()
        let end = Date().addingTimeInterval(900)
        while queue.pendingCount > 0 && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let job = queue.running {
                maxFraction = max(maxFraction, job.fraction)
                if let stage = job.stageText { stages.insert(stage) }
                if flags.contains("cancel") && job.fraction > 0.15 { queue.cancel(job) }
                sawOrder.insert(queue.jobs.map { "\($0.detail):\($0.status.rawValue)" }.joined(separator: ","))
            }
        }
        if flags.contains("queue2") { print("states seen:", sawOrder.sorted()) }
        print("max fraction", String(format: "%.2f", maxFraction), "| stages", stages.sorted())
        for job in queue.jobs {
            print("job:", job.detail, job.status, job.paths, job.failure?.message ?? "", job.failure?.detail ?? "")
        }
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 2 < args.count {
            MainActor.assumeIsolated {
                SelfTest.run(url: args[i + 1], choice: Int(args[i + 2]) ?? 0, flags: Array(args[(i + 3)...]))
            }
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshots.render(to: args[i + 1]) }
            return
        }
        BarakApp.main()
    }
}
