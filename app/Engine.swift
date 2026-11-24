// המודלים שהמנוע מחזיר לממשק, פונקציות עזר ותיקיות האפליקציה.

import AppKit
import Foundation

struct Choice: Decodable, Hashable {
    let label: String
    let size: Int
    let note: String
    let audioOnly: Bool
}

struct VideoInfo: Decodable {
    let state: String
    let title: String
    let uploader: String
    let platform: String
    let thumbnail: String?
    let duration: Double?
    let items: Int
    let choices: [Choice]
    let `default`: Int
    /// המקור לגרסת וואטסאפ: האיכות הכי טובה עד 720p
    let compact: Int
}

struct EngineFailure: Codable {
    var kind: String
    var message: String
    var detail: String?
}

struct EngineEvent {
    let type: String
    var stage: String?
    var fraction: Double?
    var speed: Double?
    var eta: Double?
    var item: Int?
    var items: Int?
    var audioOnly: Bool?
    var merge: Bool?
    var paths: [String]?
    var kind: String?
    var message: String?
    var detail: String?
}

enum JSONText {
    static func from(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - עזרים

enum Fmt {
    static func size(_ bytes: Int) -> String {
        let b = Double(bytes)
        if bytes <= 0 { return "" }
        if b >= 1e9 { return String(format: "%.2f GB", b / 1e9) }
        if b >= 1e7 { return String(format: "%.0f MB", b / 1e6) }
        return String(format: "%.1f MB", b / 1e6)
    }

    static func speed(_ s: Double?) -> String? {
        guard let s, s > 0 else { return nil }
        return String(format: "%.1f MB/s", s / 1e6)
    }

    static func time(_ t: Double?) -> String? {
        guard let t, t >= 0 else { return nil }
        let total = Int(t.rounded())
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "90", "1:30", "1:02:03" -> שניות
    static func parseTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// זמן התחלה מתוך קישור: ?t=90 / t=1m30s / t=1h2m3s
    static func startTime(in link: String) -> Double? {
        guard let items = URLComponents(string: link)?.queryItems,
              let raw = items.first(where: { $0.name == "t" || $0.name == "start" })?.value else { return nil }
        if let seconds = Double(raw.replacingOccurrences(of: "s", with: "")) { return seconds }
        var total = 0.0, number = ""
        for ch in raw {
            if ch.isNumber { number.append(ch); continue }
            let value = Double(number) ?? 0
            number = ""
            switch ch {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
        }
        return total > 0 ? total : nil
    }

    static func whenDone(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "he")
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return "היום " + formatter.string(from: date)
        }
        if Calendar.current.isDateInYesterday(date) {
            formatter.dateFormat = "HH:mm"
            return "אתמול " + formatter.string(from: date)
        }
        formatter.dateFormat = "d.M.yy"
        return formatter.string(from: date)
    }
}

/// אותה נוסחה כמו whatsapp_plan ב-engine.py, בשביל הערכת גודל מראש
enum WhatsApp {
    static func estimatedSize(duration: Double?) -> Int {
        let d = max(duration ?? 0, 1)
        let video = min(max(15_500_000 * 8 / d - 96_000, 350_000), 2_000_000)
        return Int((video + 96_000) * d / 8)
    }
}

/// אתרים שמוכרים כאתרי וידאו, בשביל ההצעה להוריד כשמעתיקים קישור
enum VideoLinks {
    static let hosts = ["youtube.com", "youtu.be", "instagram.com", "tiktok.com", "facebook.com", "fb.watch",
                        "x.com", "twitter.com", "vimeo.com", "reddit.com", "dailymotion.com", "twitch.tv",
                        "soundcloud.com", "threads.net"]

    static func isVideoLink(_ text: String) -> Bool {
        guard let host = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
        else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// תיקיות האפליקציה. השם הקודם היה "מוריד סרטונים" (VideoDownloader); מה ששמור שם עובר לכאן.
enum AppPaths {
    static let name = "Barak ⚡ Downloader"
    private static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    /// BARAK_SUPPORT_DIR: לבדיקות של "מק נקי" (בלי לגעת בתיקייה האמיתית)
    static var support: URL {
        if let dir = ProcessInfo.processInfo.environment["BARAK_SUPPORT_DIR"] { return URL(fileURLWithPath: dir) }
        return base.appendingPathComponent("Barak Downloader", isDirectory: true)
    }
    static var tools: URL { support.appendingPathComponent("tools", isDirectory: true) }
    static var legacy: URL { base.appendingPathComponent("VideoDownloader", isDirectory: true) }
    static var history: URL { support.appendingPathComponent("history.json") }

    /// אם התוסף כבר הותקן בכרום מהתיקייה הישנה, ממשיכים לעדכן אותה במקום, כדי שההתקנה לא תישבר
    static var chromeExtension: URL {
        let old = legacy.appendingPathComponent("chrome-extension", isDirectory: true)
        return FileManager.default.fileExists(atPath: old.path) ? old
            : support.appendingPathComponent("chrome-extension", isDirectory: true)
    }
}
