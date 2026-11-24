// מנוע ההורדות, בתוך האפליקציה (במקום engine.py, שנשאר רק בשביל פקודת הטרמינל).
// אותה לוגיקה בדיוק: קריאת הסרטון עם yt-dlp, בחירת פורמטים מדויקים (כדי שהגודל שמוצג יהיה האמיתי),
// הורדה עם התקדמות, חיתוך, כיווץ לוואטסאפ (VideoToolbox של אפל) וסיווג שגיאות.

import Foundation

typealias JSON = [String: Any]

private extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String? { self[key] as? String }
    func num(_ key: String) -> Double? {
        guard let n = self[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}

/// מאפשר לבטל פעולה שמריצה תהליכים (yt-dlp / ffmpeg) אחד אחרי השני
final class EngineTask {
    private(set) var cancelled = false
    var process: Process?

    func cancel() {
        cancelled = true
        process?.terminate()
    }
}

@MainActor
enum Engine {
    static let maxItems = 20  // פוסט עם כמה סרטונים (קרוסלה באינסטגרם, ציוץ עם כמה סרטונים)
    static var stateDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("barak-states") }
    private static var tools: ToolManager { .shared }

    // MARK: הרצת תהליכים

    private static func launch(_ exe: String, _ args: [String], task: EngineTask?, merge: Bool)
        -> (Process, Pipe, Pipe, AsyncStream<Int32>)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.environment = tools.environment
        let out = Pipe()
        let err = merge ? out : Pipe()
        process.standardOutput = out
        process.standardError = err
        let exit = AsyncStream<Int32> { continuation in
            process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        }
        if task?.cancelled == true { return nil }
        do { try process.run() } catch { return nil }
        task?.process = process
        return (process, out, err, exit)
    }

    private static func finish(_ process: Process, _ exit: AsyncStream<Int32>, task: EngineTask?) async -> Int32 {
        var status: Int32 = -1
        for await code in exit { status = code }
        if task?.process === process { task?.process = nil }
        return status
    }

    /// מריץ תהליך ואוסף את כל הפלט (stdout ו-stderr בנפרד)
    static func run(_ exe: String, _ args: [String], task: EngineTask?) async -> (status: Int32, out: Data, err: String) {
        guard let (process, out, err, exit) = launch(exe, args, task: task, merge: false) else { return (-1, Data(), "") }
        async let outData = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        async let errData = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
        let (o, e) = await (outData, errData)
        return (await finish(process, exit, task: task), o, String(decoding: e, as: UTF8.self))
    }

    /// מריץ תהליך וקורא את הפלט שורה אחרי שורה (stderr מתמזג ל-stdout)
    static func runLines(_ exe: String, _ args: [String], task: EngineTask?, onLine: (String) -> Void) async -> Int32 {
        guard let (process, out, _, exit) = launch(exe, args, task: task, merge: true) else { return -1 }
        do { for try await line in out.fileHandleForReading.bytes.lines { onLine(line) } } catch {}
        return await finish(process, exit, task: task)
    }

    // MARK: שגיאות

    private static let errorRules: [(String, String, String)] = [
        (#"Failed to resolve|nodename nor servname|Network is unreachable|timed out|Connection (refused|reset)"#,
         "network", "אין חיבור לאתר. בדוק את החיבור לאינטרנט ונסה שוב."),
        (#"Unsupported URL|is not a valid URL"#, "unsupported", "האתר הזה לא נתמך, או שהקישור לא מוביל לסרטון."),
        (#"IP address is blocked"#, "blocked", "האתר חוסם את ההורדה של הפוסט הזה מהרשת שלך."),
        (#"log ?in|sign in|cookies|private|confirm your age|age-restricted|rate.?limit|authenticat"#,
         "login", "הסרטון דורש התחברות: הוא פרטי, מוגבל גיל, או שהאתר לא מציג אותו בלי חשבון."),
        (#"No video formats|no video in this|There's no video|does not contain any video"#,
         "novideo", "לא מצאתי וידאו בקישור הזה. אולי זה פוסט של תמונה בלבד?"),
        (#"unavailable|not available|removed|deleted|HTTP Error 404|does not exist"#,
         "unavailable", "הסרטון לא זמין. ייתכן שהוא נמחק או הוסתר."),
    ]

    static func classify(_ log: String) -> EngineFailure {
        let errors = log.split(separator: "\n").filter { $0.hasPrefix("ERROR") }.joined(separator: "\n")
        let detail = errors.isEmpty ? String(log.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)) : errors
        for (pattern, kind, message) in errorRules
        where detail.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return EngineFailure(kind: kind, message: message, detail: detail)
        }
        return EngineFailure(kind: "generic",
                             message: "משהו השתבש. אם זה קורה גם בסרטונים אחרים, עדכון yt-dlp בדרך כלל פותר את זה.",
                             detail: detail)
    }

    // MARK: קריאת הסרטון

    static func info(_ link: String, cookies: String?, task: EngineTask) async -> Result<VideoInfo, EngineFailure> {
        var url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.lowercased().hasPrefix("http") { url = "https://" + url }
        var args = tools.ytdlpArgs + ["-J", "--no-playlist", "--no-warnings",
                                      "--playlist-items", "1:\(maxItems + 1)", url]
        if let cookies { args += ["--cookies-from-browser", cookies] }

        var timedOut = false
        let timer = Task { try? await Task.sleep(nanoseconds: 180_000_000_000); timedOut = true; task.cancel() }
        let result = await run(tools.ytdlp, args, task: task)
        timer.cancel()
        if timedOut { return .failure(EngineFailure(kind: "network", message: "האתר לא ענה בזמן. נסה שוב בעוד רגע.")) }
        if task.cancelled { return .failure(EngineFailure(kind: "cancelled", message: "")) }
        guard result.status == 0, var json = (try? JSONSerialization.jsonObject(with: result.out)) as? JSON else {
            return .failure(classify(result.err))
        }
        json["_cookies"] = cookies
        do {
            var summary = try describe(json)
            return .success(try saveState(&summary))
        } catch let failure as EngineFailure {
            return .failure(failure)
        } catch {
            return .failure(EngineFailure(kind: "generic", message: "משהו השתבש.", detail: "\(error)"))
        }
    }

    static func platform(of info: JSON) -> String {
        let key = (info.str("extractor_key") ?? info.str("extractor") ?? "").lowercased()
        let names = [("youtube", "YouTube"), ("instagram", "Instagram"), ("tiktok", "TikTok"),
                     ("facebook", "Facebook"), ("twitter", "X"), ("vimeo", "Vimeo"), ("reddit", "Reddit")]
        if let match = names.first(where: { key.hasPrefix($0.0) }) { return match.1 }
        return info.str("webpage_url_domain") ?? info.str("extractor_key") ?? ""
    }

    // MARK: בחירת איכויות

    private static func size(of f: JSON?) -> Int {
        guard let f else { return 0 }
        let exact = f.num("filesize") ?? 0
        return Int(exact > 0 ? exact : (f.num("filesize_approx") ?? 0))
    }

    private static func isAudioOnly(_ f: JSON) -> Bool { f.str("vcodec") == "none" && f.str("acodec") != "none" }

    /// vcodec חסר = לא ידוע (נפוץ ב-X ובפייסבוק), ולכן נחשב וידאו. רק "none" מפורש הוא לא-וידאו
    private static func isVideo(_ f: JSON) -> Bool {
        f.str("vcodec") != "none" && f.str("ext") != "mhtml" && !(f.str("format_note") ?? "").contains("storyboard")
    }

    /// H.264 נפתח בכל מקום (QuickTime, וואטסאפ, עורכי וידאו), אחריו VP9, ורק אז AV1
    private static func codecRank(_ f: JSON) -> Double {
        let v = (f.str("vcodec") ?? "").lowercased()
        if v.hasPrefix("avc1") || v.hasPrefix("h264") { return 3 }
        if v.hasPrefix("vp9") || v.hasPrefix("vp09") { return 2 }
        if v.hasPrefix("av01") { return 1 }
        return 0
    }

    private static func best(_ formats: [JSON], by key: (JSON) -> [Double]) -> JSON? {
        formats.max { a, b in key(a).lexicographicallyPrecedes(key(b)) }
    }

    /// קבצים רגילים (https) קודם: גודל ידוע והורדה מהירה יותר מ-HLS
    private static func pickVideo(_ formats: [JSON]) -> JSON? {
        best(formats) { f in
            [f.str("protocol") == "https" ? 1 : 0, codecRank(f), f.num("fps") ?? 0, f.num("tbr") ?? 0, Double(size(of: f))]
        }
    }

    /// AAC סטריאו רגיל, בלי גרסת "drc" (דחיסת עוצמה) ובלי 5.1
    private static func pickAudio(_ formats: [JSON]) -> JSON? {
        best(formats) { f in
            [(f.str("acodec") ?? "").hasPrefix("mp4a") ? 1 : 0,
             (f.str("format_id") ?? "").contains("drc") ? 0 : 1,
             (f.num("audio_channels") ?? 2) <= 2 ? 1 : 0,
             f.str("protocol") == "https" ? 1 : 0,
             f.num("abr") ?? f.num("tbr") ?? 0]
        }
    }

    static let qtNote = "לא נפתח ב-QuickTime, כן ב-VLC/IINA"

    struct Option {
        let label: String
        let rank: Double
        let format: String
        let size: Int
        let note: String
        let audioOnly: Bool
        /// קצב הוידאו (ביט לשנייה), בשביל קידוד מחדש בחיתוך
        let bitrate: Double
    }

    static func options(for entry: JSON) -> [Option] {
        let formats = (entry["formats"] as? [JSON]) ?? [entry]
        let video = formats.filter(isVideo)
        let audio = pickAudio(formats.filter(isAudioOnly))
        let withHeight = video.filter { ($0.num("height") ?? 0) > 0 }
        var result: [Option] = []

        func spec(for f: JSON) -> (String, Int) {
            let id = f.str("format_id") ?? ""
            let hasAudio = f.str("acodec") != "none"
            if hasAudio || audio == nil { return (id, size(of: f)) }
            return ("\(id)+\(audio!.str("format_id") ?? "")", size(of: f) + size(of: audio))
        }

        if !withHeight.isEmpty {
            for height in Set(withHeight.compactMap { $0.num("height") }).sorted(by: >) {
                guard let f = pickVideo(withHeight.filter { $0.num("height") == height }) else { continue }
                let shortSide = min(f.num("width") ?? height, height)  // סרטון אנכי: 1080x1920 הוא 1080p
                let label = "\(Int(shortSide))p"
                if result.contains(where: { $0.label == label }) { continue }
                let (format, bytes) = spec(for: f)
                let v = (f.str("vcodec") ?? "").lowercased()
                let note = v.hasPrefix("vp9") || v.hasPrefix("vp09") || v.hasPrefix("av01") ? qtNote : ""
                result.append(Option(label: label, rank: shortSide, format: format, size: bytes, note: note,
                                     audioOnly: false, bitrate: (f.num("vbr") ?? f.num("tbr") ?? 0) * 1000))
            }
        } else if !video.isEmpty {
            // בלי מידע על רזולוציה (למשל פייסבוק): HD/SD לפי השם, או "איכות מקורית"
            let sorted = video.sorted { ($0.num("tbr") ?? 0, Double(size(of: $0))) > ($1.num("tbr") ?? 0, Double(size(of: $1))) }
            for (i, f) in sorted.prefix(3).enumerated() {
                let id = (f.str("format_id") ?? "").lowercased()
                let label = ["hd", "sd"].contains(id) ? id.uppercased() : (i == 0 ? "איכות מקורית" : "חלופה \(i)")
                let (format, bytes) = spec(for: f)
                result.append(Option(label: label, rank: Double(-i), format: format, size: bytes, note: "",
                                     audioOnly: false, bitrate: (f.num("tbr") ?? 0) * 1000))
            }
        }

        let withSound = video.filter { $0.str("acodec") != "none" }  // יש סרטונים שקטים לגמרי
        if let source = audio ?? pickVideo(withSound) {
            let duration = entry.num("duration") ?? 0
            result.append(Option(label: "אודיו בלבד (MP3)", rank: -100, format: source.str("format_id") ?? "",
                                 size: Int(duration * 245_000 / 8),  // MP3 באיכות הכי גבוהה: בערך 245kbps
                                 note: "", audioOnly: true, bitrate: 0))
        }
        return result
    }

    /// סיכום לתצוגה + האיכויות. בפוסט עם כמה סרטונים, כל בחירה חלה על כולם.
    static func describe(_ info: JSON) throws -> JSON {
        if (info["is_live"] as? Bool) == true {
            throw EngineFailure(kind: "live", message: "זה שידור חי. אפשר להוריד אותו רק אחרי שהשידור מסתיים.")
        }
        var entries = info.str("_type") == "playlist" ? ((info["entries"] as? [Any]) ?? []).compactMap { $0 as? JSON } : [info]
        if entries.count > maxItems {
            throw EngineFailure(kind: "playlist", message: "זו רשימה של הרבה סרטונים. הדבק קישור לסרטון בודד.")
        }
        var perEntry = entries.map(options(for:))
        entries = zip(entries, perEntry).filter { !$0.1.isEmpty }.map(\.0)
        perEntry = perEntry.filter { !$0.isEmpty }
        guard !entries.isEmpty else {
            throw EngineFailure(kind: "novideo", message: "לא מצאתי וידאו בקישור הזה. אולי זה פוסט של תמונה בלבד?")
        }

        // רשימת האיכויות: כל מה שקיים לפחות באחד הסרטונים
        var labels: [Option] = []
        for options in perEntry { for o in options where !labels.contains(where: { $0.label == o.label }) { labels.append(o) } }
        labels.sort { $0.rank > $1.rank }

        var choices: [JSON] = []
        for wanted in labels {
            var picks: [Option] = []
            for options in perEntry {
                let sameKind = options.filter { $0.audioOnly == wanted.audioOnly }
                let pool = sameKind.isEmpty ? options : sameKind
                let pick = pool.first { $0.label == wanted.label }
                    ?? pool.first { $0.rank <= wanted.rank }
                    ?? pool.min { $0.rank < $1.rank }!
                picks.append(pick)
            }
            choices.append([
                "label": wanted.label,
                "size": picks.map(\.size).reduce(0, +),
                "note": picks.contains { !$0.note.isEmpty } ? qtNote : "",
                "audio_only": wanted.audioOnly,
                "rank": wanted.rank,
                "picks": picks.map { ["format": $0.format, "size": $0.size, "bitrate": $0.bitrate] as JSON },
            ])
        }

        func isAudio(_ c: JSON) -> Bool { c["audio_only"] as? Bool ?? false }
        // ברירת מחדל: האיכות הכי גבוהה שנפתחת בכל נגן (בדרך כלל 1080p)
        let defaultIndex = choices.firstIndex { ($0.str("note") ?? "").isEmpty && !isAudio($0) } ?? 0
        // המקור לגרסת וואטסאפ: הכי טוב עד 720p (אין טעם להוריד 4K כדי לכווץ אותו)
        let videos = choices.indices.filter { !isAudio(choices[$0]) }
        let compact = videos.first { i in
            let rank = choices[i].num("rank") ?? 0
            return rank > 0 && rank <= 720 && (choices[i].str("note") ?? "").isEmpty
        } ?? videos.last ?? defaultIndex

        let thumbnail = info.str("thumbnail") ?? entries.lazy.compactMap { $0.str("thumbnail") }.first
        let duration = entries.compactMap { $0.num("duration") }.reduce(0, +)
        return [
            "title": info.str("title") ?? entries[0].str("title") ?? "",
            "uploader": info.str("uploader") ?? info.str("channel") ?? entries[0].str("uploader") ?? "",
            "platform": platform(of: info),
            "thumbnail": thumbnail as Any,
            "duration": duration > 0 ? duration : NSNull(),
            "items": entries.count,
            "choices": choices,
            "default": defaultIndex,
            "compact": compact,
            "_entries": entries,
            "_cookies": info["_cookies"] ?? NSNull(),
        ]
    }

    /// שומר את הסיכום לקובץ (בשביל "נסה שוב" מההיסטוריה) ומחזיר את מה שהממשק צריך
    static func saveState(_ summary: inout JSON) throws -> VideoInfo {
        let fm = FileManager.default
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        for old in (try? fm.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if Date().timeIntervalSince(date) > 7 * 86_400 { try? fm.removeItem(at: old) }
        }
        let file = stateDir.appendingPathComponent(UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: summary).write(to: file)
        return videoInfo(summary, state: file.path)
    }

    static func videoInfo(_ s: JSON, state: String) -> VideoInfo {
        let choices = ((s["choices"] as? [JSON]) ?? []).map {
            Choice(label: $0.str("label") ?? "", size: Int($0.num("size") ?? 0), note: $0.str("note") ?? "",
                   audioOnly: $0["audio_only"] as? Bool ?? false)
        }
        return VideoInfo(state: state, title: s.str("title") ?? "", uploader: s.str("uploader") ?? "",
                         platform: s.str("platform") ?? "", thumbnail: s.str("thumbnail"),
                         duration: s.num("duration"), items: Int(s.num("items") ?? 1), choices: choices,
                         default: Int(s.num("default") ?? 0), compact: Int(s.num("compact") ?? 0))
    }

    // MARK: הורדה

    static let whatsappTarget = 15_500_000.0  // בייטים: נשלח מהר ונראה טוב בטלפון
    static let whatsappAudio = 96_000.0

    /// (קצב וידאו בביט לשנייה, הצלע הקצרה המקסימלית) כך שהקובץ ייצא בערך 15MB
    static func whatsappPlan(duration: Double) -> (Double, Int) {
        let d = max(duration, 1)
        let video = min(max(whatsappTarget * 8 / d - whatsappAudio, 350_000), 2_000_000)
        return (video, video >= 700_000 ? 720 : 480)
    }

    /// לשם הקובץ: 1m05s (בלי נקודתיים, ש-Finder מציג כלוכסן)
    static func clock(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        let (h, m, s) = (t / 3600, t % 3600 / 60, t % 60)
        return h > 0 ? String(format: "%dh%02dm%02ds", h, m, s) : String(format: "%dm%02ds", m, s)
    }

    static func outputName(_ summary: JSON, choice: JSON, index: Int, options: JSON) -> String {
        let style = options.str("name_style") ?? "title_quality"
        var name = "%(title).120B"
        if style == "uploader_title", let uploader = summary.str("uploader"), !uploader.isEmpty {
            let safe = String(uploader.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "/", with: "-").prefix(60))
            name = "\(safe) - %(title).100B"
        }
        if ((summary["_entries"] as? [Any])?.count ?? 1) > 1 { name += " \(index + 1)" }
        var tags: [String] = []
        if !(choice["audio_only"] as? Bool ?? false) {
            if options["whatsapp"] as? Bool == true { tags.append("WhatsApp") }
            else if style != "title" { tags.append(choice.str("label") ?? "") }
        }
        if let trim = options["trim"] as? [Double], trim.count == 2 { tags.append("\(clock(trim[0]))-\(clock(trim[1]))") }
        return name + (tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))") + ".%(ext)s"
    }

    private static func uniquePath(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)")
            n += 1
        }
        return candidate
    }

    /// מוריד לפי מה שנבחר. האירועים (progress / stage / done / error) מגיעים דרך onEvent.
    static func download(state: String, choice index: Int, options optionsJSON: String, task: EngineTask,
                         onEvent: (EngineEvent) -> Void) async {
        guard let data = FileManager.default.contents(atPath: state),
              let summary = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
              let choices = summary["choices"] as? [JSON], choices.indices.contains(index),
              let entries = summary["_entries"] as? [JSON] else {
            onEvent(EngineEvent(type: "error", kind: "generic",
                                message: "המידע על הסרטון פג תוקף. הדבק את הקישור שוב."))
            return
        }
        let options = ((try? JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))) as? JSON) ?? [:]
        let choice = choices[index]
        let picks = (choice["picks"] as? [JSON]) ?? []
        let audioOnly = choice["audio_only"] as? Bool ?? false
        let n = entries.count
        let whatsapp = options["whatsapp"] as? Bool == true && !audioOnly
        let trim = n == 1 ? (options["trim"] as? [Double]).flatMap { $0.count == 2 ? $0 : nil } : nil

        var outDir = URL(fileURLWithPath: options.str("out_dir") ?? AppSettings.shared.outURL.path)
        if options["by_platform"] as? Bool == true {
            outDir.appendPathComponent((summary.str("platform").flatMap { $0.isEmpty ? nil : $0 } ?? "אחר")
                .replacingOccurrences(of: "/", with: "-"))
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let tmp = fm.temporaryDirectory.appendingPathComponent("barak-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        // בוואטסאפ ההורדה היא רק חצי מהעבודה; החצי השני הוא הכיווץ
        let span = whatsapp ? 0.5 : 1.0
        var saved: [String] = []

        for (i, (entry, pick)) in zip(entries, picks).enumerated() {
            let entryFile = tmp.appendingPathComponent("entry\(i).json")
            try? JSONSerialization.data(withJSONObject: entry).write(to: entryFile)
            let format = pick.str("format") ?? ""
            let pickSize = pick.num("size") ?? 0
            let home = whatsapp ? tmp.appendingPathComponent("ready") : outDir
            var args = tools.ytdlpArgs + [
                "--load-info-json", entryFile.path, "-f", format,
                "--no-warnings", "--no-mtime", "--newline", "--progress",  // --no-mtime: שיופיע כחדש בתיקייה
                "-P", home.path, "-P", "temp:\(tmp.appendingPathComponent("parts").path)",
                "-o", outputName(summary, choice: choice, index: i, options: options),
                "--progress-template", "download:@@P %(progress.downloaded_bytes)s %(progress.total_bytes)s "
                    + "%(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s %(info.format_id)s",
                "--print", "post_process:@@M", "--print", "after_move:@@F %(filepath)s",
                "--embed-metadata",
            ]
            args += audioOnly ? ["-x", "--audio-format", "mp3", "--audio-quality", "0", "--embed-thumbnail"]
                              : ["--merge-output-format", "mp4"]
            if let trim {
                args += ["--download-sections", "*\(trim[0])-\(trim[1])"]
                if !audioOnly {
                    // חיתוך מדויק מקודד מחדש את הקטע; ב-FFmpeg שלנו (LGPL) המקודד הוא של אפל
                    let duration = entry.num("duration") ?? 0
                    let source = pick.num("bitrate").flatMap { $0 > 0 ? $0 : nil }
                        ?? (duration > 0 ? pickSize * 8 / duration : 8_000_000)
                    let bitrate = Int(min(max(source * 1.2, 1_500_000), 25_000_000))
                    args += ["--force-keyframes-at-cuts", "--downloader-args",
                             "ffmpeg_o:-c:v h264_videotoolbox -allow_sw 1 -b:v \(bitrate) -c:a aac -b:a 192k"]
                }
            } else if options["sponsorblock"] as? Bool == true && summary.str("platform") == "YouTube" {
                args += ["--sponsorblock-remove", "sponsor,selfpromo,interaction"]
            }
            if let cookies = summary.str("_cookies") { args += ["--cookies-from-browser", cookies] }

            if trim != nil { onEvent(EngineEvent(type: "stage", stage: "trimming", item: i + 1, items: n)) }
            var parts: [String: (Double, Double)] = [:]
            var log: [String] = []
            var files: [String] = []
            let status = await runLines(tools.ytdlp, args, task: task) { line in
                if line.hasPrefix("@@P "), trim == nil {
                    let f = line.dropFirst(4).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                    func value(_ k: Int) -> Double? { k < f.count ? Double(f[k]) : nil }
                    let fid = f.count > 5 ? f[5] : ""
                    parts[fid] = (value(0) ?? 0, value(1) ?? value(2) ?? 0)
                    let totals = parts.values.map(\.1)
                    let allKnown = parts.count == format.filter { $0 == "+" }.count + 1 && !totals.contains(0)
                    // הגודל שהאתר מדווח מראש לא תמיד נכון (ב-X הוא מנופח), אז ברגע שכל החלקים
                    // בהורדה, סומכים על הגודל האמיתי שלהם
                    let expected = allKnown ? totals.reduce(0, +) : max(pickSize, totals.reduce(0, +))
                    let got = parts.values.map(\.0).reduce(0, +)
                    let fraction = expected > 0 ? min(got / expected, 0.99) : 0
                    onEvent(EngineEvent(type: "progress", fraction: (Double(i) + fraction * span) / Double(n),
                                        speed: value(3), eta: value(4), item: i + 1, items: n))
                } else if line == "@@M", trim == nil {
                    onEvent(EngineEvent(type: "stage", stage: "processing", item: i + 1, items: n,
                                        audioOnly: audioOnly, merge: format.contains("+")))
                } else if line.hasPrefix("@@F ") {
                    files.append(String(line.dropFirst(4)))
                } else if !line.hasPrefix("@@") {
                    log.append(line)
                }
            }
            if task.cancelled { return }
            if status != 0 {
                let failure = classify(log.joined(separator: "\n"))
                onEvent(EngineEvent(type: "error", kind: failure.kind, message: failure.message, detail: failure.detail))
                return
            }

            if whatsapp {
                for file in files {
                    let source = URL(fileURLWithPath: file)
                    let target = uniquePath(outDir.appendingPathComponent(source.lastPathComponent))
                    let ok = await compressForWhatsApp(source, to: target, task: task) { fraction in
                        onEvent(EngineEvent(type: "progress", stage: "compress",
                                            fraction: (Double(i) + span + fraction * (1 - span)) / Double(n),
                                            item: i + 1, items: n))
                    }
                    if task.cancelled { return }
                    guard ok else {
                        onEvent(EngineEvent(type: "error", kind: "generic", message: "הכיווץ לוואטסאפ נכשל."))
                        return
                    }
                    saved.append(target.path)
                }
            } else {
                saved += files
            }
        }
        onEvent(EngineEvent(type: "done", paths: saved))
    }

    private static func probeDuration(_ file: URL) async -> Double {
        let result = await run(tools.ffprobe, ["-v", "error", "-show_entries", "format=duration",
                                               "-of", "default=nw=1:nk=1", file.path], task: nil)
        return Double(String(decoding: result.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// H.264 (המקודד של אפל) + AAC, קטן. כותב לקובץ זמני ומעביר רק בסוף, כדי שביטול לא ישאיר קובץ חלקי.
    static func compressForWhatsApp(_ source: URL, to target: URL, task: EngineTask,
                                    progress: (Double) -> Void) async -> Bool {
        let duration = await probeDuration(source)
        let (video, side) = whatsappPlan(duration: duration)
        // לרוחב: גובה עד side; לאורך: רוחב עד side. תמיד מספר זוגי
        let scale = "scale=w='if(gte(iw,ih),-2,trunc(min(\(side),iw)/2)*2)':h='if(gte(iw,ih),trunc(min(\(side),ih)/2)*2,-2)'"
        let partial = source.deletingLastPathComponent().appendingPathComponent("compressing.mp4")
        let args = ["-hide_banner", "-nostdin", "-y", "-i", source.path, "-vf", scale, "-fpsmax", "30",
                    "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-profile:v", "high", "-b:v", String(Int(video)),
                    "-c:a", "aac", "-b:a", "96k", "-ac", "2", "-movflags", "+faststart",
                    "-progress", "pipe:1", "-nostats", "-loglevel", "error", partial.path]
        let status = await runLines(tools.ffmpeg, args, task: task) { line in
            if line.hasPrefix("out_time_us="), duration > 0, let us = Double(line.dropFirst(12)) {
                progress(min(max(us / 1e6 / duration, 0), 0.99))
            }
        }
        guard status == 0, !task.cancelled else { return false }
        return (try? FileManager.default.moveItem(at: partial, to: target)) != nil
    }
}

extension EngineFailure: Error {}
