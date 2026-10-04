import AppKit
import SwiftUI

@main
struct AVARecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Build step: `AVA Recorder --render-icon <png>` draws the app icon and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            AppIcon.writePNG(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        // `AVA Recorder --test-follow <audio or .txt> <script.md>` prints where the prompter would move.
        if let i = args.firstIndex(of: "--test-follow"), i + 2 < args.count {
            FollowTest.run(source: args[i + 1], script: args[i + 2])
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshots.render(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))
            exit(0)
        }
    }

    var body: some Scene {
        Window("AVA Recorder", id: "panel") {
            PanelView(studio: Studio.shared)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var prompter: PrompterController?
    private var pill: RecordingPillController?
    private var awake: NSObjectProtocol?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.applicationIconImage = AppIcon.image()
        // Filming days are long and quiet: the screens must not dim or sleep mid-take.
        awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                       reason: "Filming")
        Studio.shared.boot()
        // The prompter is on hold (4 Oct): it is built but its strip is not shown to the presenter.
        prompter = PrompterController(studio: Studio.shared)
        pill = RecordingPillController(studio: Studio.shared)
        let args = CommandLine.arguments
        if !args.contains("--self-test") {
            // Fill the monitor. Not macOS full screen: the window has to step aside while
            // recording, and a full-screen Space would leave the presenter on an empty screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible }),
                      let screen = window.screen ?? NSScreen.main else { return }
                window.setFrame(screen.visibleFrame, display: true, animate: false)
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                    NSApp.terminate(nil)
                }
            }
        }
        if let i = args.firstIndex(of: "--self-test"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
            // `--record-main` points the test at the screen that shows pop-up banners.
            if args.contains("--record-main"),
               let number = NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                Studio.shared.displayID = CGDirectDisplayID(number.uint32Value)
            }
            Studio.shared.selfTest(seconds: seconds)
        }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Studio.shared.isBusy else { return .terminateNow }
        // Never lose a take: close the files properly before quitting.
        Studio.shared.stopForQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// Hiding the panel while recording must not count as closing it, so quitting is tied to the
    /// panel's own close button instead.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Graphite body, a hairline ring and the lit green key: the panel's record key as an icon.
enum AppIcon {
    @MainActor
    static func view() -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x222826), Color(hex: 0x0C0F0E)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 12)
            Circle()
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 7)
                .frame(width: 470, height: 470)
            Circle()
                .fill(LinearGradient(colors: [Palette.signalHot, Palette.signal, Color(hex: 0x23955A)], startPoint: .top, endPoint: .bottom))
                .frame(width: 330, height: 330)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 2))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 10)
        }
        .frame(width: 1024, height: 1024)
    }

    @MainActor
    static func image() -> NSImage? {
        let renderer = ImageRenderer(content: view())
        renderer.scale = 1
        return renderer.nsImage
    }

    @MainActor
    static func writePNG(to url: URL) {
        let renderer = ImageRenderer(content: view())
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
