// המסכים: החלון הראשי (קישור, הכנה, רשימת הורדות) והחלונית בסרגל התפריטים.

import AppKit
import SwiftUI

let brandGradient = LinearGradient(colors: [Color(red: 1, green: 0.37, blue: 0.43),
                                            Color(red: 0.48, green: 0.18, blue: 0.97)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)

extension View {
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

// MARK: - החלון הראשי

struct ContentView: View {
    @ObservedObject var prep: Preparer
    @ObservedObject var queue: DownloadQueue
    @ObservedObject var settings: AppSettings
    @ObservedObject var tools: ToolManager = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Header()
            UpdateBanner(updates: .shared)
            if tools.phase == .ready {
                LinkField(prep: prep)
                prepArea
            } else {
                ToolSetupCard(tools: tools)
            }
            if !queue.jobs.isEmpty {
                DownloadsList(queue: queue, prep: prep)
            }
            Footer(settings: settings)
        }
        .padding(24)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.layoutDirection, .rightToLeft)
        .animation(.easeInOut(duration: 0.18), value: prep.phase)
        .dropDestination(for: URL.self) { urls, _ in
            guard let link = urls.first, tools.phase == .ready else { return false }
            prep.load(link.absoluteString)
            return true
        }
    }

    var prepArea: some View {
            Group {
                switch prep.phase {
                case .idle: IdleHint(compact: !queue.jobs.isEmpty)
                case .fetching: FetchingCard(prep: prep)
                case .ready: if let info = prep.info { ReadyCard(prep: prep, info: info, queueBusy: queue.running != nil) }
                case .failed: FailedCard(prep: prep)
                }
            }
            .transition(.opacity)
    }
}

/// אייקון האפליקציה עצמו (כך שהכותרת תמיד תואמת לאייקון שנבחר)
struct AppBadge: View {
    var size: CGFloat = 44
    var body: some View {
        // מהקובץ עצמו: applicationIconImage מחזיר גרסה מעובדת לפי סגנון האייקונים של המערכת (למשל כהה)
        Image(nsImage: Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
              ?? NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size * 1.24, height: size * 1.24)  // לאייקון יש שוליים שקופים
            .frame(width: size, height: size)
    }
}

struct Header: View {
    var body: some View {
        HStack(spacing: 12) {
            AppBadge()
            VStack(alignment: .leading, spacing: 2) {
                Text(AppPaths.name).font(.title2.bold())
                Text("יוטיוב · אינסטגרם · טיקטוק · פייסבוק · X ועוד").font(.callout).foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("הגדרות")
        }
    }
}

struct LinkField: View {
    @ObservedObject var prep: Preparer
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    TextField("הדבק כאן קישור לסרטון", text: $prep.url)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { prep.fetch() }
                        .disabled(prep.isBusy)
                    if !prep.url.isEmpty && !prep.isBusy {
                        Button {
                            prep.reset()
                            focused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("נקה")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12)))

                Group {
                    if prep.url.isEmpty {
                        Button(action: pasteAndGo) { Label("הדבק", systemImage: "doc.on.clipboard") }
                    } else {
                        Button { prep.fetch() } label: { Text("המשך").frame(minWidth: 44) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(prep.isBusy)
            }
            if prep.phase == .idle && prep.pastedFromClipboard {
                Text("הקישור מהלוח כבר בשדה. לחץ Enter כדי להמשיך.").font(.caption).foregroundStyle(.secondary)
            } else if prep.phase == .idle && prep.clipboardHasLink && prep.url.isEmpty {
                Text("יש קישור בלוח. לחץ 'הדבק' או ⌘V.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { focused = true }
    }

    /// הדבקה אמיתית לשדה (כמו ⌘V), כדי ש-macOS לא יבקש הרשאה לקרוא את הלוח
    private func pasteAndGo() {
        focused = true
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            DispatchQueue.main.async { prep.fetch() }
        }
    }
}

struct IdleHint: View {
    var compact = false
    var body: some View {
        VStack(spacing: compact ? 4 : 10) {
            if !compact {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(brandGradient)
            }
            Text("הדבק קישור, או גרור אותו לכאן").font(compact ? .callout : .headline)
            if !compact {
                Text("תוכל לבחור איכות, לחתוך קטע או להכין גרסה לוואטסאפ לפני ההורדה.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 12 : 28)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }
}

struct FetchingCard: View {
    @ObservedObject var prep: Preparer
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("בודק את הקישור…")
            Spacer()
            Button("ביטול") { prep.cancel() }.keyboardShortcut(.cancelAction)
        }
        .card()
    }
}

struct PlatformBadge: View {
    let name: String
    var color: Color {
        switch name {
        case "YouTube": return .red
        case "Instagram": return .pink
        case "Facebook": return .blue
        case "TikTok", "X": return .primary
        default: return .gray
        }
    }
    var body: some View {
        Text(name)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

struct Thumbnail: View {
    let url: String?
    var width: CGFloat = 128
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08))
            Image(systemName: "play.rectangle.fill").font(width > 80 ? .title2 : .body).foregroundStyle(.tertiary)
            if let url, let link = URL(string: url) {
                AsyncImage(url: link) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.clear }
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: width > 80 ? 8 : 6, style: .continuous))
    }
}

struct VideoHeader: View {
    let info: VideoInfo
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumbnail(url: info.thumbnail)
            VStack(alignment: .leading, spacing: 5) {
                Text(info.title).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !info.platform.isEmpty { PlatformBadge(name: info.platform) }
                    if !info.uploader.isEmpty { Text(info.uploader).lineLimit(1) }
                    if info.items == 1, let time = Fmt.time(info.duration), (info.duration ?? 0) > 0 {
                        Text("·")
                        Text(time).monospacedDigit()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if info.items > 1 {
                    Text("\(info.items) סרטונים בפוסט, כולם יורדו").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct QualityRow: View {
    let choice: Choice
    let size: Int
    let isSelected: Bool
    let isRecommended: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Image(systemName: choice.audioOnly ? "music.note" : "film")
                .frame(width: 16).foregroundStyle(.secondary)
            Text(choice.label).fontWeight(isSelected ? .semibold : .regular)
            if isRecommended {
                Text("מומלץ").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.green.opacity(0.13)))
            }
            if !choice.note.isEmpty {
                Text(choice.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Fmt.size(size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

struct ReadyCard: View {
    @ObservedObject var prep: Preparer
    let info: VideoInfo
    let queueBusy: Bool

    var hasVideo: Bool { info.choices.contains { !$0.audioOnly } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoHeader(info: info)
            Divider()
            options
            if prep.whatsapp {
                whatsappSummary
            } else {
                Text("באיזו איכות להוריד?").font(.subheadline.weight(.semibold))
                VStack(spacing: 2) {
                    ForEach(Array(info.choices.enumerated()), id: \.offset) { index, choice in
                        QualityRow(choice: choice, size: prep.estimatedSize(for: index),
                                   isSelected: prep.selected == index,
                                   isRecommended: index == info.default && info.choices.count > 2) {
                            prep.selected = index
                        }
                    }
                }
            }
            Button { prep.enqueue() } label: {
                Label(queueBusy ? "הוסף לתור" : "הורדה",
                      systemImage: queueBusy ? "text.badge.plus" : "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isTrimInvalid)
        }
        .card()
    }

    var isTrimInvalid: Bool {
        if case .invalid = prep.trim { return true }
        return false
    }

    @ViewBuilder var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                if prep.canTrim(info) {
                    Toggle(isOn: $prep.trimOn) { Label("חיתוך קטע", systemImage: "scissors") }
                }
                if hasVideo {
                    Toggle(isOn: $prep.whatsapp) { Label("קובץ קטן לוואטסאפ", systemImage: "paperplane") }
                }
            }
            .toggleStyle(.checkbox)
            if prep.trimOn && prep.canTrim(info) {
                HStack(spacing: 8) {
                    Text("מ-")
                    TimeField(text: $prep.trimStart)
                    Text("עד")
                    TimeField(text: $prep.trimEnd)
                    switch prep.trim {
                    case .valid(let start, let end):
                        Text("אורך: \(Fmt.time(end - start) ?? "")").foregroundStyle(.secondary).monospacedDigit()
                    case .invalid:
                        Text("טווח לא תקין").foregroundStyle(.red)
                    case .off:
                        EmptyView()
                    }
                }
                .font(.callout)
                .padding(.leading, 22)
            }
        }
    }

    var whatsappSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("מכווץ לשליחה מהירה: H.264 עד 720p")
                Text("מתנגן בכל טלפון. בסרטונים ארוכים האיכות יורדת כדי לשמור על גודל קטן.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("~" + Fmt.size(prep.estimatedSize(for: prep.effectiveChoice))).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.green.opacity(0.08)))
    }
}

struct TimeField: View {
    @Binding var text: String
    var body: some View {
        TextField("0:00", text: $text)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .frame(width: 72)
            .environment(\.layoutDirection, .leftToRight)
    }
}

struct FailedCard: View {
    @ObservedObject var prep: Preparer

    var body: some View {
        let failure = prep.failure ?? EngineFailure(kind: "generic", message: "משהו השתבש.")
        let canLogin = failure.kind == "login" && !prep.usedCookies
        let canUpdate = ["generic", "unavailable", "novideo", "unsupported"].contains(failure.kind)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.message).fixedSize(horizontal: false, vertical: true)
                    if canLogin {
                        Text("אם אתה מחובר לאתר בכרום, אפשר לנסות דרך החשבון שלך. המק יבקש לאשר גישה ל-Keychain פעם אחת.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let status = prep.updateStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                if canLogin {
                    Button("נסה דרך החשבון שלי בכרום") { prep.fetch(withCookies: true) }.buttonStyle(.borderedProminent)
                }
                Button("נסה שוב") { prep.fetch(withCookies: prep.usedCookies) }
                if canUpdate {
                    Button(prep.isUpdating ? "מעדכן…" : "עדכן את yt-dlp") { prep.updateEngine() }
                        .disabled(prep.isUpdating)
                }
                Spacer()
                Button("קישור אחר") { prep.reset() }.buttonStyle(.link)
            }
            if let detail = failure.detail, !detail.isEmpty {
                DisclosureGroup("פרטים טכניים") {
                    ScrollView {
                        Text(detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    .frame(maxHeight: 90)
                }
                .font(.caption)
            }
        }
        .card()
    }
}

// MARK: - רשימת ההורדות

struct DownloadsList: View {
    @ObservedObject var queue: DownloadQueue
    @ObservedObject var prep: Preparer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("הורדות").font(.headline)
                if queue.pendingCount > 0 {
                    Text("\(queue.pendingCount) בתהליך").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if queue.hasFinished {
                    Button("ניקוי הרשימה") { queue.clearFinished() }.buttonStyle(.link).font(.caption)
                }
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(queue.jobs) { job in
                        JobRow(job: job, queue: queue, prep: prep)
                    }
                }
            }
            .frame(height: min(CGFloat(queue.jobs.count) * 62, 310))
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: DownloadJob
    let queue: DownloadQueue
    let prep: Preparer

    var statusText: String {
        switch job.status {
        case .queued: return "ממתין בתור"
        case .running:
            if let stage = job.stageText, job.indeterminate || job.stageText != nil {
                return job.indeterminate ? stage : "\(stage) \(Int(job.fraction * 100))%"
            }
            var parts = ["\(Int(job.fraction * 100))%"]
            if let speed = Fmt.speed(job.speed) { parts.append(speed) }
            if let eta = Fmt.time(job.eta), (job.eta ?? 0) > 0 { parts.append("נותרו \(eta)") }
            if let item = job.itemText { parts.append(item) }
            return parts.joined(separator: " · ")
        case .done: return job.fileExists ? Fmt.whenDone(job.finishedAt) : "הקובץ הוזז או נמחק"
        case .failed: return job.failure?.message ?? "נכשל"
        case .cancelled: return "בוטל"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(url: job.thumbnail, width: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if !job.platform.isEmpty { PlatformBadge(name: job.platform) }
                    Text(job.detail)
                    Text("·")
                    Text(statusText)
                        .foregroundStyle(job.status == .failed ? Color.red : Color.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
                if job.status == .running {
                    if job.indeterminate {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    } else {
                        ProgressView(value: job.fraction).progressViewStyle(.linear).controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 4)
            actions
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if job.status == .done { open() } }
        .contextMenu { menu }
    }

    @ViewBuilder var actions: some View {
        HStack(spacing: 4) {
            switch job.status {
            case .queued, .running:
                iconButton("xmark.circle.fill", "ביטול") { queue.cancel(job) }
            case .done:
                iconButton("play.circle.fill", "פתח", action: open).disabled(!job.fileExists)
                iconButton("magnifyingglass.circle.fill", "הצג ב-Finder", action: reveal).disabled(!job.fileExists)
            case .failed, .cancelled:
                iconButton("arrow.clockwise.circle.fill", "נסה שוב") { queue.retry(job, prepare: prep) }
                iconButton("trash.circle.fill", "הסר מהרשימה") { queue.remove(job) }
            }
        }
    }

    @ViewBuilder var menu: some View {
        if job.status == .done {
            Button("פתח", action: open).disabled(!job.fileExists)
            Button("הצג ב-Finder", action: reveal).disabled(!job.fileExists)
            Divider()
        }
        Button("הורד שוב (בחירת איכות)") { prep.load(job.url) }
        Button("העתק קישור") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(job.url, forType: .string)
        }
        Divider()
        Button(job.isActive ? "בטל והסר" : "הסר מהרשימה") { queue.remove(job) }
    }

    func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2).symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help(help)
    }

    func open() { if let path = job.paths.first { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting(job.paths.map { URL(fileURLWithPath: $0) }) }
}

struct Footer: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
            Text(settings.byPlatform ? "נשמר בתיקייה \(settings.outURL.lastPathComponent), לפי פלטפורמה" : "נשמר בתיקייה \(settings.outURL.lastPathComponent)")
            Button("פתח את התיקייה") { NSWorkspace.shared.open(settings.outURL) }.buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - סרגל התפריטים

struct MenuBarPanel: View {
    @ObservedObject var queue: DownloadQueue
    @ObservedObject var watcher: ClipboardWatcher
    @Environment(\.openWindow) private var openWindow

    var active: [DownloadJob] { queue.jobs.filter(\.isActive) }
    var recent: [DownloadJob] { Array(queue.jobs.filter { $0.status == .done }.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AppBadge(size: 24)
                Text(AppPaths.name).font(.headline)
            }
            if watcher.linkWaiting {
                Button { watcher.downloadCopiedLink() } label: {
                    Label("הורד את הקישור שהועתק", systemImage: "link.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            if !active.isEmpty {
                ForEach(active) { job in MiniJobRow(job: job) }
            } else if recent.isEmpty {
                Text("אין הורדות כרגע.").foregroundStyle(.secondary).font(.callout)
            }
            if !recent.isEmpty {
                Text("הורדו לאחרונה").font(.caption).foregroundStyle(.secondary)
                ForEach(recent) { job in MiniJobRow(job: job) }
            }
            Divider()
            HStack {
                Button("פתח את החלון") {
                    if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                SettingsLink { Text("הגדרות…") }
                Button("יציאה") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 320)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

struct MiniJobRow: View {
    @ObservedObject var job: DownloadJob
    var body: some View {
        HStack(spacing: 8) {
            Thumbnail(url: job.thumbnail, width: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.caption.weight(.medium)).lineLimit(1)
                if job.status == .running {
                    ProgressView(value: job.indeterminate ? nil : job.fraction).progressViewStyle(.linear).controlSize(.mini)
                } else {
                    Text(job.status == .queued ? "ממתין בתור" : job.detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if job.status == .done, let path = job.paths.first {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                    Image(systemName: "play.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}
