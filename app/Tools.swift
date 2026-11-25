// הכלים החיצוניים (yt-dlp, Deno, FFmpeg): לא נארזים בתוך האפליקציה. בהפעלה הראשונה מורידים אותם
// מהמקורות הרשמיים לפי המעבד של המשתמש, בודקים SHA-256 ומתקינים תחת Application Support.
// yt-dlp מתעדכן לבד (פעם ביום לכל היותר), כי האתרים משתנים כל הזמן.

import CryptoKit
import Foundation
import SwiftUI

// SHA-256 של ffmpeg-<גרסה>-<arch>.zip מתוך SHA256SUMS ב-Release tools-ffmpeg-9.0.2
let FFMPEG_SHA_ARM64 = "aeaddf5969eb96278e1b80ab99975cf26e291d486011fbc519784ca4d3288430"
let FFMPEG_SHA_X86_64 = "a933e3ba05c056867200d5babae15e19f9f06559bd5853b1101ea13bd276659d"

enum Arch {
    static var current: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

struct ToolSpec {
    let id: String
    let version: String
    let url: URL
    let sha256: String
    /// גודל בבייטים (לחישוב התקדמות כוללת לפני שהשרת מדווח)
    let size: Int
    /// שם התיקייה שבה הגרסה הזו מותקנת
    var folder: String { "\(version)-\(id == "yt-dlp" ? "universal" : Arch.current)" }
}

/// הגרסאות המדויקות שהאפליקציה מורידה. כדי לעדכן: גרסה + SHA-256 מהקבצים הרשמיים של כל פרויקט.
enum ToolManifest {
    static let ytdlp = ToolSpec(
        id: "yt-dlp", version: "2026.11.23",
        url: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.11.23/yt-dlp_macos.zip")!,
        sha256: "43fc87fc581f64b48c366ce20b9cacb9c2949cc1ac4b9eca56fe25ac52dbb63b", size: 54_175_412)

    static var deno: ToolSpec {
        let arm = Arch.current == "arm64"
        let asset = arm ? "deno-aarch64-apple-darwin.zip" : "deno-x86_64-apple-darwin.zip"
        return ToolSpec(
            id: "deno", version: "2.9.8",
            url: URL(string: "https://github.com/denoland/deno/releases/download/v2.9.8/\(asset)")!,
            sha256: arm ? "9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e"
                        : "4b2f5edd2639b7470f034238b321d7002d8dfb4726d8558f52c17afac370eb2c",
            size: arm ? 38_770_795 : 42_797_031)
    }

    /// נבנה מהמקור הרשמי ב-GitHub Actions של הריפו (scripts/build-ffmpeg.sh), ברישיון LGPL
    static var ffmpeg: ToolSpec {
        let arm = Arch.current == "arm64"
        return ToolSpec(
            id: "ffmpeg", version: "9.0.2",
            url: URL(string: "https://github.com/barakWork95/barak-downloader/releases/download/tools-ffmpeg-9.0.2/ffmpeg-9.0.2-\(Arch.current).zip")!,
            sha256: arm ? FFMPEG_SHA_ARM64 : FFMPEG_SHA_X86_64,
            size: arm ? 20_668_852 : 22_453_114)
    }

    static var all: [ToolSpec] { [ytdlp, deno, ffmpeg] }
}

@MainActor
final class ToolManager: ObservableObject {
    static let shared = ToolManager()

    enum Phase: Equatable { case checking, ready, installing, failed(String) }

    @Published var phase: Phase = .checking
    @Published var fraction = 0.0
    @Published var current = ""
    @Published var ytdlpVersion = ""
    @Published var updateMessage: String?
    @Published var isUpdating = false

    private var installed: [String: String] = [:]
    private var stateURL: URL { AppPaths.tools.appendingPathComponent("installed.json") }

    // MARK: נתיבים

    /// בפיתוח בלבד: BARAK_SYSTEM_TOOLS=1 משתמש בכלים של Homebrew
    static let useSystemTools = ProcessInfo.processInfo.environment["BARAK_SYSTEM_TOOLS"] == "1"

    private func dir(_ id: String) -> URL? {
        guard let version = installed[id] else { return nil }
        let folder = id == "yt-dlp" ? "\(version)-universal" : "\(version)-\(Arch.current)"
        return AppPaths.tools.appendingPathComponent(id).appendingPathComponent(folder)
    }

    var ytdlp: String {
        Self.useSystemTools ? "/opt/homebrew/bin/yt-dlp" : dir("yt-dlp")?.appendingPathComponent("yt-dlp_macos").path ?? ""
    }
    var deno: String {
        Self.useSystemTools ? "/opt/homebrew/bin/deno" : dir("deno")?.appendingPathComponent("deno").path ?? ""
    }
    var ffmpeg: String {
        Self.useSystemTools ? "/opt/homebrew/bin/ffmpeg" : dir("ffmpeg")?.appendingPathComponent("ffmpeg").path ?? ""
    }
    var ffprobe: String {
        Self.useSystemTools ? "/opt/homebrew/bin/ffprobe" : dir("ffmpeg")?.appendingPathComponent("ffprobe").path ?? ""
    }

    /// הסביבה לכל הרצה: רק הכלים שלנו ופקודות המערכת. בלי Homebrew, כמו אצל כל משתמש
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dirs = [ytdlp, deno, ffmpeg].map { ($0 as NSString).deletingLastPathComponent }
        env["PATH"] = (dirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        return env
    }

    /// הדגלים ש-yt-dlp צריך כדי למצוא את Deno ואת FFmpeg שלנו
    var ytdlpArgs: [String] {
        ["--no-js-runtimes", "--js-runtimes", "deno:\(deno)",
         "--ffmpeg-location", (ffmpeg as NSString).deletingLastPathComponent]
    }

    // MARK: התקנה

    func ensureReady() async {
        guard phase != .ready, phase != .installing else { return }
        if Self.useSystemTools {
            ytdlpVersion = "Homebrew"
            phase = .ready
            return
        }
        loadState()
        let missing = ToolManifest.all.filter { !isInstalled($0) }
        if missing.isEmpty {
            ytdlpVersion = installed["yt-dlp"] ?? ""
            phase = .ready
            Task { await autoUpdateYtDlp() }
            return
        }
        phase = .installing
        let total = Double(missing.map(\.size).reduce(0, +))
        var done = 0.0
        do {
            for spec in missing {
                current = spec.id
                try await install(spec, archiveURL: spec.url, sha256: spec.sha256) { part in
                    self.fraction = min((done + part * Double(spec.size)) / total, 0.99)
                }
                done += Double(spec.size)
            }
            fraction = 1
            ytdlpVersion = installed["yt-dlp"] ?? ""
            phase = .ready
        } catch {
            phase = .failed((error as? ToolError)?.message ?? error.localizedDescription)
        }
    }

    func retry() {
        phase = .checking
        Task { await ensureReady() }
    }

    private func isInstalled(_ spec: ToolSpec) -> Bool {
        // yt-dlp יכול להיות בגרסה חדשה יותר (עדכון אוטומטי); את השאר מחזיקים בגרסה המדויקת
        guard let version = installed[spec.id], spec.id == "yt-dlp" || version == spec.version,
              let dir = dir(spec.id) else { return false }
        let exe = spec.id == "yt-dlp" ? "yt-dlp_macos" : spec.id
        return FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent(exe).path)
    }

    private func install(_ spec: ToolSpec, archiveURL: URL, sha256: String,
                         progress: @escaping (Double) -> Void) async throws {
        let fm = FileManager.default
        let archive = try await Download.file(archiveURL, progress: progress)
        defer { try? fm.removeItem(at: archive) }
        guard try Download.sha256(of: archive) == sha256.lowercased() else {
            throw ToolError("הקובץ של \(spec.id) לא עבר את בדיקת האבטחה (SHA-256). נסה שוב.")
        }
        let base = AppPaths.tools.appendingPathComponent(spec.id)
        let target = base.appendingPathComponent(spec.folder)
        let staging = base.appendingPathComponent(".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try await Download.unzip(archive, into: staging)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: staging, to: target)
        // גרסאות ישנות של אותו כלי
        for old in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent != spec.folder && !old.lastPathComponent.hasPrefix(".") {
            try? fm.removeItem(at: old)
        }
        installed[spec.id] = spec.version
        saveState()
    }

    // MARK: עדכון yt-dlp

    private var lastCheckKey: String { "ytdlpLastUpdateCheck" }

    func autoUpdateYtDlp() async {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        _ = await updateYtDlp()
    }

    /// בודק את הגרסה האחרונה ב-GitHub ומתקין אם צריך. מחזיר (הצליח, גרסה או הודעה)
    func updateYtDlp() async -> (ok: Bool, message: String) {
        if Self.useSystemTools { return (false, "בפיתוח משתמשים ב-yt-dlp של Homebrew") }
        do {
            let api = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
            let (data, _) = try await URLSession.shared.data(from: api)
            guard let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = release["tag_name"] as? String,
                  let assets = release["assets"] as? [[String: Any]],
                  let zip = assets.first(where: { $0["name"] as? String == "yt-dlp_macos.zip" })?["browser_download_url"] as? String,
                  let sums = assets.first(where: { $0["name"] as? String == "SHA2-256SUMS" })?["browser_download_url"] as? String,
                  let zipURL = URL(string: zip), let sumsURL = URL(string: sums)
            else { throw ToolError("לא הצלחתי לקרוא את פרטי הגרסה האחרונה של yt-dlp.") }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            if tag == installed["yt-dlp"] { return (true, tag) }
            let (sumsData, _) = try await URLSession.shared.data(from: sumsURL)
            guard let line = String(decoding: sumsData, as: UTF8.self).split(separator: "\n")
                    .first(where: { $0.hasSuffix(" yt-dlp_macos.zip") }),
                  let sha = line.split(separator: " ").first
            else { throw ToolError("לא נמצא קוד אימות לגרסה \(tag).") }
            let spec = ToolSpec(id: "yt-dlp", version: tag, url: zipURL, sha256: String(sha), size: 54_000_000)
            try await install(spec, archiveURL: zipURL, sha256: String(sha)) { _ in }
            ytdlpVersion = tag
            return (true, tag)
        } catch {
            return (false, (error as? ToolError)?.message ?? error.localizedDescription)
        }
    }

    /// מכפתור "בדוק עדכון" בהגדרות
    func checkForUpdate() {
        isUpdating = true
        updateMessage = nil
        Task {
            let result = await updateYtDlp()
            isUpdating = false
            updateMessage = result.ok ? "מעודכן: גרסה \(result.message)" : "העדכון נכשל: \(result.message)"
        }
    }

    // MARK: מצב שמור

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        installed = state
    }

    private func saveState() {
        try? FileManager.default.createDirectory(at: AppPaths.tools, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: installed, options: [.prettyPrinted]) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }
}

struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// הורדה עם התקדמות, SHA-256 ופריסת zip
enum Download {
    static func file(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func unzip(_ archive: URL, into dir: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, dir.path]
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
        if status != 0 { throw ToolError("פריסת הקובץ נכשלה.") }
    }

    final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
        let progress: @MainActor (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>?

        init(progress: @escaping @MainActor (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            Task { @MainActor in self.progress(fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // את הקובץ הזמני חייבים להעביר לפני שהפונקציה חוזרת
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                continuation?.resume(throwing: ToolError("ההורדה נכשלה (HTTP \(http.statusCode))."))
            } else if (try? FileManager.default.moveItem(at: location, to: kept)) != nil {
                continuation?.resume(returning: kept)
            } else {
                continuation?.resume(throwing: ToolError("לא הצלחתי לשמור את הקובץ שהורד."))
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                continuation?.resume(throwing: ToolError("אין חיבור לאינטרנט, או שההורדה נקטעה. (\(error.localizedDescription))"))
                continuation = nil
            }
        }
    }
}

// MARK: - מסך ההכנה בהפעלה הראשונה

struct ToolSetupCard: View {
    @ObservedObject var tools: ToolManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch tools.phase {
            case .failed(let message):
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ההכנה לא הושלמה").font(.headline)
                        Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("נסה שוב") { tools.retry() }.buttonStyle(.borderedProminent)
            default:
                Text("מכין את מנוע ההורדות").font(.headline)
                Text("בפעם הראשונה בלבד: מוריד את הכלים שהאפליקציה צריכה, בערך 135MB, מהאתרים הרשמיים שלהם.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("yt-dlp · FFmpeg · Deno").font(.caption).foregroundStyle(.tertiary)
                if tools.phase == .checking {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: tools.fraction).progressViewStyle(.linear)
                    Text("\(Int(tools.fraction * 100))% · \(tools.current)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }
}
