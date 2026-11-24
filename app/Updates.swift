// בדיקת גרסה חדשה של האפליקציה מול GitHub Releases (פעם ביום). אם יש, מוצג פס עם קישור להורדה.

import AppKit
import SwiftUI

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repo = "barakWork95/barak-downloader"
    static let downloadPage = URL(string: "https://barakwork95.github.io/barak-downloader/")!

    @Published var available: String?
    private let lastCheckKey = "appUpdateLastCheck"
    private let dismissedKey = "appUpdateDismissed"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else {
            available = UserDefaults.standard.string(forKey: "appUpdateAvailable").flatMap(newer)
            return
        }
        Task { await check() }
    }

    func check() async {
        let api = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        guard let (data, _) = try? await URLSession.shared.data(from: api),
              let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = release["tag_name"] as? String else { return }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        UserDefaults.standard.set(version, forKey: "appUpdateAvailable")
        available = newer(version)
    }

    /// הגרסה, אם היא חדשה יותר מהמותקנת ולא נדחתה
    private func newer(_ version: String) -> String? {
        guard version.compare(Self.currentVersion, options: .numeric) == .orderedDescending,
              UserDefaults.standard.string(forKey: dismissedKey) != version else { return nil }
        return version
    }

    func dismiss() {
        UserDefaults.standard.set(available, forKey: dismissedKey)
        available = nil
    }
}

struct UpdateBanner: View {
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        if let version = updates.available {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text("גרסה חדשה זמינה: \(version)").font(.callout.weight(.medium))
                Spacer()
                Button("להורדה") { NSWorkspace.shared.open(UpdateChecker.downloadPage) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button { updates.dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("לא עכשיו")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.1)))
        }
    }
}
