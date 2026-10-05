import AppKit
import ScreenCaptureKit
import SwiftUI

// What the screen recording shows: an entire screen, or one window, chosen from pictures the way
// Google Meet asks. The choice can be remembered so Screen shares it at once next time.

enum ShareTarget: Codable, Equatable {
    case screen(UInt32)
    /// One window, found again by its app and title (window numbers change every launch).
    case window(app: String, appName: String, title: String)

    var label: String {
        switch self {
        case .screen: "Entire screen"
        case .window(_, let appName, let title): title.isEmpty || title == appName ? "\(appName) window" : "\(appName): \(title)"
        }
    }

    static func saved() -> ShareTarget {
        if let data = UserDefaults.standard.data(forKey: "shareTarget"),
           let target = try? JSONDecoder().decode(ShareTarget.self, from: data) {
            return target
        }
        return .screen(UInt32(UserDefaults.standard.integer(forKey: "display")))
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "shareTarget") }
    }

    /// The window again: the same title first, otherwise that app's biggest window.
    static func find(app: String, title: String, in content: SCShareableContent) -> SCWindow? {
        let mine = windows(in: content).filter { w in
            w.owningApplication.map { $0.bundleIdentifier == app || $0.applicationName == app } ?? false
        }
        return mine.first { $0.title == title } ?? mine.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Windows a person would share: on screen, a real size, not this app's and not the system's.
    static func windows(in content: SCShareableContent) -> [SCWindow] {
        let skip: Set<String> = [Bundle.main.bundleIdentifier ?? "inc.ava.recorder", "com.apple.dock", "com.apple.WindowManager",
                                 "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.Spotlight",
                                 "com.apple.systemuiserver", "com.apple.wallpaper.agent"]
        return content.windows
            .filter { w in
                guard w.isOnScreen, w.windowLayer == 0, w.frame.width >= 120, w.frame.height >= 80,
                      let app = w.owningApplication, !skip.contains(app.bundleIdentifier) else { return false }
                return true
            }
            .sorted {
                let a = $0.owningApplication?.applicationName ?? "", b = $1.owningApplication?.applicationName ?? ""
                return a == b ? ($0.title ?? "") < ($1.title ?? "") : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
    }
}

// MARK: - The chooser

/// A floating chooser over the recorded screen. It is never in the recording (the app's own
/// windows are kept out).
@MainActor
enum SharePicker {
    enum Purpose { case shareNow, chooseDefault }

    private static var panel: NSPanel?

    static func show(_ purpose: Purpose, studio: Studio) {
        close()
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: SharePickerView(studio: studio, purpose: purpose, close: close).preferredColorScheme(.dark))
        let screen = studio.displayID.flatMap(DisplayChoice.screen(for:)) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: visible.midX - 380, y: visible.midY - 280))
        }
        panel = p
        p.makeKeyAndOrderFront(nil)
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// One thing that can be shared, with its picture.
private struct ShareChoice: Identifiable {
    var id: String
    var target: ShareTarget
    var title: String
    var detail: String
    var icon: NSImage?
    /// Nil only in design snapshots.
    var filter: SCContentFilter?
    var aspect: CGFloat
}

struct SharePickerView: View {
    @ObservedObject var studio: Studio
    var purpose: SharePicker.Purpose
    var close: () -> Void
    /// Design snapshots only: made-up screens and windows.
    var sample = false

    @State private var tab: Tab = .screen
    @State private var screens: [ShareChoice] = []
    @State private var windows: [ShareChoice] = []
    @State private var pictures: [String: CGImage] = [:]
    @State private var picked: String?
    @State private var everyTime = false
    @State private var loading = true
    @State private var failure: String?

    enum Tab { case screen, window }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What to share")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(purpose == .shareNow ? "Pick the whole screen or one window. Only what you pick goes into the video."
                                          : "This is shared when you press Screen. Only what you pick goes into the video.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.dim)
            }
            .padding(.bottom, 16)

            Segments(choices: [("Entire screen", Tab.screen), ("A window", .window)], selected: tab) { tab = $0; picked = nil }
                .padding(.bottom, 14)

            grid
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.top, 14)

            HStack(spacing: 18) {
                // A window's own app is the sound people mean, like the video playing in Chrome.
                Tick(on: studio.screenAudio, title: "Include \(pickedApp.map { "\($0)'s sound" } ?? "the Mac's sound")") { studio.screenAudio.toggle() }
                Tick(on: everyTime, title: purpose == .shareNow ? "Share this every time, without asking" : "Use it without asking") { everyTime.toggle() }
                Spacer(minLength: 0)
                SmallButton(title: "Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                SmallButton(title: purpose == .shareNow ? "Share" : "Use this", primary: true) { done() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(width: 760, height: 560)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.body))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .task { await load() }
    }

    private var shown: [ShareChoice] { tab == .screen ? screens : windows }

    /// The app of the picked window, if a window is picked.
    private var pickedApp: String? {
        if case .window(_, let appName, _) = choice?.target { return appName }
        return nil
    }
    private var choice: ShareChoice? { shown.first { $0.id == picked } }

    @ViewBuilder private var grid: some View {
        if let failure {
            Text(failure).font(.system(size: 13)).foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            Text(tab == .window ? "No windows are open. Open the app you want to show, then come back." : "No screen found.")
                .font(.system(size: 13)).foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let tiles = LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 14)], spacing: 16) {
                ForEach(shown) { item in
                    Tile(item: item, picture: pictures[item.id], picked: item.id == picked) { picked = item.id }
                        .onTapGesture(count: 2) { picked = item.id; done() }
                }
            }
            if Snapshots.active { tiles } else { ScrollView { tiles.padding(.vertical, 2) } }
        }
    }

    private func done() {
        guard let choice else { return }
        // A window shares its own app's sound; the entire screen shares every app's.
        if studio.screenAudio {
            if case .window(let app, let appName, _) = choice.target { studio.rememberSound(from: app, name: appName) }
            else { studio.rememberSound(from: nil, name: nil) }
        }
        if everyTime || purpose == .chooseDefault {
            studio.shareTarget = choice.target
        }
        if everyTime { studio.askBeforeSharing = false }
        close()
        if purpose == .shareNow { studio.shareScreen(choice.target) }
    }

    private func load() async {
        guard !Snapshots.active else {
            if sample { stageSample() }
            loading = false
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            screens = content.displays.map { d in
                let name = studio.displays.first { $0.id == d.displayID }?.name ?? "Screen"
                return ShareChoice(id: "screen-\(d.displayID)", target: .screen(d.displayID), title: name,
                                   detail: "\(Int(d.frame.width)) × \(Int(d.frame.height))", icon: nil,
                                   filter: SCContentFilter(display: d, excludingWindows: []),
                                   aspect: d.frame.width / max(d.frame.height, 1))
            }
            windows = ShareTarget.windows(in: content).map { w in
                let app = w.owningApplication
                let appName = app?.applicationName ?? "App"
                let title = (w.title ?? "").isEmpty ? appName : (w.title ?? appName)
                let icon = app.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon }
                return ShareChoice(id: "window-\(w.windowID)", target: .window(app: app?.bundleIdentifier ?? appName, appName: appName, title: w.title ?? ""),
                                   title: title, detail: appName, icon: icon,
                                   filter: SCContentFilter(desktopIndependentWindow: w),
                                   aspect: w.frame.width / max(w.frame.height, 1))
            }
            // Start on what was chosen before.
            switch studio.shareTarget {
            case .screen(let id):
                tab = .screen
                picked = screens.first { $0.target == .screen(id) }?.id ?? screens.first?.id
            case .window(let app, _, let title):
                tab = .window
                picked = windows.first { matches($0.target, app: app, title: title) }?.id
                    ?? windows.first { matches($0.target, app: app, title: nil) }?.id
            }
            loading = false
            for item in screens + windows {
                guard let filter = item.filter else { continue }
                let config = SCStreamConfiguration()
                config.width = 400
                config.height = Int(400 / max(item.aspect, 0.2))
                config.showsCursor = false
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    pictures[item.id] = image
                }
            }
        } catch {
            failure = "Screen recording is not allowed yet. Allow AVA Recorder in System Settings, Privacy, then try again."
            loading = false
        }
    }

    init(studio: Studio, purpose: SharePicker.Purpose, close: @escaping () -> Void, sample: Bool = false) {
        self.studio = studio
        self.purpose = purpose
        self.close = close
        self.sample = sample
        if sample {
            // An off-screen render runs no tasks, so the made-up choices are set here.
            let made = Self.sampleChoices()
            _screens = State(initialValue: made.screens)
            _windows = State(initialValue: made.windows)
            _tab = State(initialValue: .window)
            _picked = State(initialValue: "w1")
            _loading = State(initialValue: false)
        }
    }

    private func stageSample() {
        let made = Self.sampleChoices()
        screens = made.screens
        windows = made.windows
        tab = .window
        picked = "w1"
    }

    private static func sampleChoices() -> (screens: [ShareChoice], windows: [ShareChoice]) {
        func icon(_ path: String) -> NSImage? { NSWorkspace.shared.icon(forFile: path) }
        let screens = [ShareChoice(id: "s1", target: .screen(1), title: "Samsung S24R35A", detail: "1920 × 1080", icon: nil, filter: nil, aspect: 16 / 9),
                   ShareChoice(id: "s2", target: .screen(2), title: "Built-in Display", detail: "1470 × 956", icon: nil, filter: nil, aspect: 1.54)]
        let windows = [
            ShareChoice(id: "w1", target: .window(app: "com.google.Chrome", appName: "Google Chrome", title: "Seller Central"),
                        title: "Seller Central", detail: "Google Chrome", icon: icon("/System/Applications/Safari.app"), filter: nil, aspect: 1.6),
            ShareChoice(id: "w2", target: .window(app: "com.apple.Keynote", appName: "Keynote", title: "FBA fees 2026"),
                        title: "FBA fees 2026", detail: "Keynote", icon: icon("/System/Applications/Notes.app"), filter: nil, aspect: 1.5),
            ShareChoice(id: "w3", target: .window(app: "com.apple.finder", appName: "Finder", title: "Downloads"),
                        title: "Downloads", detail: "Finder", icon: icon("/System/Library/CoreServices/Finder.app"), filter: nil, aspect: 2.1),
            ShareChoice(id: "w4", target: .window(app: "com.apple.Notes", appName: "Notes", title: "Video ideas"),
                        title: "Video ideas", detail: "Notes", icon: icon("/System/Applications/Notes.app"), filter: nil, aspect: 1.3),
        ]
        return (screens, windows)
    }

    /// The same app, and the same window title unless `title` is nil.
    private func matches(_ target: ShareTarget, app: String, title: String?) -> Bool {
        if case .window(let a, _, let t) = target { return a == app && (title == nil || t == title) }
        return false
    }
}

/// A picture of a screen or window, its name under it, lit green when picked.
private struct Tile: View {
    var item: ShareChoice
    var picture: CGImage?
    var picked: Bool
    var pick: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.well)
                    if let picture {
                        Image(decorative: picture, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    } else {
                        Image(systemName: item.icon == nil ? "display" : "macwindow")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Palette.engraved)
                    }
                }
                .frame(height: 124)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(picked ? Palette.signal : hover ? Color.white.opacity(0.2) : Palette.hairline, lineWidth: picked ? 2 : 1))
                HStack(spacing: 7) {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(picked ? Palette.ink : Palette.dim)
                            .lineLimit(1)
                        Text(item.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.engraved)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A tick box with its words, the same as the panel's.
struct Tick: View {
    var on: Bool
    var title: String
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(on ? Palette.signal : Palette.engraved)
                Text(title).font(.system(size: 12)).foregroundStyle(Palette.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
