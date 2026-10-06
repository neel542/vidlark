import AVFoundation
import SwiftUI

// Settings: everything that is not needed to press record, each with one plain sentence on what
// it does. The main panel keeps only the camera picture, the sources and the record key.

enum SettingsPage: String, CaseIterable, Identifiable {
    case video, quality, after, effects, prompter, live, mac, cameraGuide

    /// The settings themselves; the guides sit under them in the sidebar.
    static var settings: [SettingsPage] { allCases.filter { $0 != .cameraGuide } }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "In the video"
        case .quality: "Camera quality"
        case .after: "After each take"
        case .effects: "Camera effects"
        case .prompter: "Prompter and remote"
        case .live: "Live view"
        case .mac: "This Mac"
        case .cameraGuide: "Connect a camera"
        }
    }

    var symbol: String {
        switch self {
        case .video: "rectangle.inset.filled.and.person.filled"
        case .quality: "camera.aperture"
        case .after: "checklist"
        case .effects: "sparkles"
        case .prompter: "text.alignleft"
        case .live: "dot.radiowaves.left.and.right"
        case .mac: "laptopcomputer"
        case .cameraGuide: "video.badge.plus"
        }
    }

    var intro: String {
        switch self {
        case .video: "Every take starts on your face. Press Screen in the recording box to share the screen."
        case .quality: "How sharp the camera records. Sharper looks better on YouTube and makes bigger files."
        case .after: "What AVA Recorder makes once you press stop. The camera and screen files are always kept."
        case .effects: "macOS can change the camera picture for every app on this Mac. Only you can switch these, in Video Effects. Here is what each one does, and whether it is on."
        case .prompter: "The prompter shows the script one line at a time. A key, your voice or a Bluetooth remote moves it on."
        case .live: "Watch the shoot from another laptop or a phone, in a web browser. There is no login: the secret link is the key, so only share it with people you trust."
        case .mac: "Space, power and speed for a long take."
        case .cameraGuide: "Any camera this Mac can see can be a source: your iPhone, a USB webcam or a real camera. Cameras connect by cable, or by Wi-Fi the way an iPhone does. Bluetooth is too slow for video."
        }
    }
}

/// The Settings window, opened from the gear in the panel or Command-Comma.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static let page = SettingsSelection()

    static func show(_ open: SettingsPage? = nil) {
        if let open { page.current = open }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: SettingsView(studio: .shared, selection: page).preferredColorScheme(.dark))
        host.sizingOptions = [.minSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Settings"
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(Palette.body)
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 920, height: 660))
        w.center()
        _ = w.setFrameAutosaveName("AVA Settings")
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { window = nil }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

final class SettingsSelection: ObservableObject {
    @Published var current: SettingsPage = .video
}

struct SettingsView: View {
    @ObservedObject var studio: Studio
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.hairline).frame(width: 1)
            page
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(DeviceBody())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            ForEach(SettingsPage.settings) { item in
                SidebarItem(page: item, selected: item == selection.current, alert: alert(on: item)) {
                    selection.current = item
                }
            }
            Text("Guides")
                .engraved()
                .padding(.horizontal, 10)
                .padding(.top, 22)
                .padding(.bottom, 6)
            SidebarItem(page: .cameraGuide, selected: selection.current == .cameraGuide, alert: false) {
                selection.current = .cameraGuide
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        // The title bar band holds the traffic lights; snapshots have none.
        .padding(.top, Snapshots.active ? 28 : 52)
        .frame(width: 224)
        .background(Palette.face.opacity(0.6))
    }

    /// A page with something on that usually should not be, shown with an amber lamp.
    private func alert(on item: SettingsPage) -> Bool {
        switch item {
        case .mac: (studio.freeGB ?? 100) < 20 || !studio.power.pluggedIn
        case .live: studio.liveFailure != nil
        default: false
        }
    }

    private var page: some View {
        let current = selection.current
        let content = VStack(alignment: .leading, spacing: 0) {
            Text(current.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(current.intro)
                .font(.system(size: 13))
                .foregroundStyle(Palette.dim)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.top, 6)
            Group {
                switch current {
                case .video: VideoSettings(studio: studio)
                case .quality: QualitySettings(studio: studio)
                case .after: AfterSettings(studio: studio)
                case .effects: EffectsSettings(studio: studio)
                case .prompter: PrompterSettings(studio: studio)
                case .live: LiveSettings(studio: studio)
                case .mac: MacSettings(studio: studio)
                case .cameraGuide: CameraGuide(studio: studio)
                }
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 40)
        .padding(.top, Snapshots.active ? 30 : 48)
        .padding(.bottom, 40)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(nil, value: current)

        return Group {
            if Snapshots.active {
                // An off-screen render cannot draw a scroll view.
                VStack { content; Spacer(minLength: 0) }
            } else {
                ScrollView { content }
            }
        }
    }
}

// MARK: - Pages

private struct VideoSettings: View {
    @ObservedObject var studio: Studio

    var body: some View {
        SettingsGroup {
            SettingRow("Your face on the screen",
                       "While the video shows the screen, your face sits in a corner in this shape. Drag it anywhere during the take. The camera file is always saved too.") {
                EmptyView()
            } below: {
                ShapePicker(studio: studio)
            }
            SettingRow("Ask what to share each time",
                       "On: pressing Screen during a take shows the screens and windows, with your last pick ready. Off: it shares your last pick straight away.") {
                Switch(on: studio.askBeforeSharing) { studio.askBeforeSharing = $0 }
            }
            SettingRow("Include the Mac's sound",
                       "Adds what the Mac plays, like a video on the screen, as a second sound track. Your microphone is always recorded. During a take, the Mac sound button switches it and picks the app.") {
                Switch(on: studio.screenAudio) { studio.screenAudio = $0 }
            } below: {
                if studio.screenAudio, let name = studio.soundFromName {
                    HStack(spacing: 10) {
                        Text("Only \(name)'s sound, as picked last time.").note()
                        SmallButton(title: "Every app instead") { studio.rememberSound(from: nil, name: nil) }
                    }
                }
            }
        }
        .disabled(studio.isBusy)
    }
}

private struct QualitySettings: View {
    @ObservedObject var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let format = studio.cameraFormat, let name = studio.cameraName {
                Readout(lamp: .ok, text: "\(name) records \(format.text). About \(String(format: "%.1f", format.gigabytesPer15Minutes)) GB for 15 minutes.")
            } else {
                Readout(lamp: .off, text: "No camera is connected yet.")
            }
            SettingsGroup {
                SettingRow("Sharpness",
                           "Best uses the sharpest picture the camera offers. If a camera cannot do the one you pick, it uses the next one down.") {
                    Segments(choices: CameraQuality.allCases.map { ($0.title, $0) }, selected: studio.cameraQuality) { studio.cameraQuality = $0 }
                }
                SettingRow("Smooth motion",
                           "60 frames a second instead of 30, when the camera can. Smoother hand movement, and files about twice as big.") {
                    Switch(on: studio.smoothMotion) { studio.smoothMotion = $0 }
                }
            }
            .disabled(studio.isBusy)
            if studio.isBusy {
                Text("Quality can be changed once this take has stopped.").note()
            } else if studio.light {
                Text("Light mode is on (This Mac), so the camera records at most 1080p, 30 frames a second.").note()
            }
        }
    }
}

private struct AfterSettings: View {
    @ObservedObject var studio: Studio

    var body: some View {
        SettingsGroup {
            SettingRow("Transcript and chapters",
                       "Writes every word with its time, YouTube chapters, and a list of the places you said \"retake\". Takes a minute or two after a long take.") {
                Switch(on: studio.writeTranscript) { studio.writeTranscript = $0 }
            }
            SettingRow("Finished video",
                       "One video, video.mp4, that follows your Me and Screen clicks, ready to upload. Turning it off saves time and space.") {
                Switch(on: studio.makeVideo) { studio.makeVideo = $0 }
            }
            SettingRow("Where recordings go", Library.root.path) {
                SmallButton(title: "Open folder") { NSWorkspace.shared.open(Library.root) }
            }
        }
    }
}

private struct EffectsSettings: View {
    @ObservedObject var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                EffectRow(name: "Studio Light", on: studio.touchUpOn, bestOff: false,
                          what: "Lights your face and gently darkens the background, like a soft lamp in front of you. Many people like it on.")
                EffectRow(name: "Portrait", on: studio.portraitOn, bestOff: false,
                          what: "Blurs the background behind you.")
                EffectRow(name: "Center Stage", on: studio.centerStageOn, bestOff: true,
                          what: "Moves and zooms the picture to keep you in the middle. It can drift while you talk with your hands, so it is usually best off.")
            }
            HStack(spacing: 14) {
                SmallButton(title: "Open Video Effects", primary: true) { studio.openVideoEffects() }
                Text("Switch them in the panel that opens. AVA Recorder sees the change within a few seconds.").note()
            }
        }
    }
}

private struct PrompterSettings: View {
    @ObservedObject var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                SettingRow("Show the prompter during takes",
                           "A strip with the script, at the top of the screen that is not recorded. Drag it next to the camera.") {
                    Switch(on: studio.showPrompter) { studio.showPrompter = $0 }
                }
                SettingRow("How it moves on",
                           "My voice: it listens and moves on as you finish each line. Key: only when you press it. By itself: the script scrolls up at a steady speed. The key and the remote always work too.") {
                    Segments(choices: [("My voice", Pace.voice), ("Key", .key), ("By itself", .scroll)], selected: pace) { set($0) }
                }
                if studio.autoScroll {
                    SettingRow("Scrolling speed",
                               "Medium is about 140 words a minute, a calm talking pace. The key under Esc skips ahead; Shift and the key goes back.") {
                        Segments(choices: [("Slow", 110), ("Medium", 140), ("Fast", 170)], selected: studio.scrollWordsPerMinute) { studio.scrollWordsPerMinute = $0 }
                    }
                }
                SettingRow("Text size", "Bigger is easier to read from further away; fewer words fit. Drag the strip's edge to make it taller.") {
                    Segments(choices: [("Small", 0.8), ("Medium", 1.0), ("Large", 1.3), ("Extra large", 1.6)], selected: studio.prompterSize) { studio.prompterSize = $0 }
                }
                SettingRow("Keyboard", "The key under Esc moves to the next line. Hold Shift with it to go back.") {
                    HStack(spacing: 8) {
                        KeyCap(text: "`")
                        Text("under Esc").font(.system(size: 12)).foregroundStyle(Palette.dim)
                    }
                }
            }
            RemoteSettings()
        }
    }

    private enum Pace { case voice, key, scroll }

    private var pace: Pace { studio.autoScroll ? .scroll : studio.followVoice ? .voice : .key }

    private func set(_ pace: Pace) {
        studio.autoScroll = pace == .scroll
        studio.followVoice = pace == .voice
    }
}

private struct LiveSettings: View {
    @ObservedObject var studio: Studio

    var body: some View {
        SettingsGroup {
            SettingRow("Live view",
                       "Home Wi-Fi works on a laptop or phone on the same Wi-Fi. Anywhere also works away from home, through a free secure link that changes each time it starts.") {
                Segments(choices: [("Off", LiveMode.off), ("Home Wi-Fi", .wifi), ("Anywhere", .anywhere)], selected: studio.liveMode) { studio.liveMode = $0 }
            }
            if studio.liveMode != .off {
                SettingRow("The link", studio.liveLink ?? (studio.liveMode == .anywhere ? "Connecting. The link appears in about 10 seconds." : "Not ready yet.")) {
                    HStack(spacing: 8) {
                        SmallButton(title: "Copy link") { studio.copyLiveLink() }
                            .disabled(studio.liveLink == nil)
                        SmallButton(title: "New link") { studio.newLiveLink() }
                    }
                } below: {
                    Text("New link stops every link handed out before from working.").note()
                }
            }
            if let failure = studio.liveFailure {
                Readout(lamp: .fail, text: failure).padding(.vertical, 12)
            }
        }
    }
}

private struct MacSettings: View {
    @ObservedObject var studio: Studio

    var body: some View {
        SettingsGroup {
            SettingRow("Free space", "A 15 minute take needs about 3 GB, plus about 0.5 GB for the finished video.") {
                StatusValue(lamp: studio.freeGB.map { $0 < 5 ? .fail : $0 < 20 ? .warn : .ok } ?? .off,
                            text: studio.freeGB.map { "\(Int($0)) GB" } ?? "Unknown")
            }
            SettingRow("Power", "Plug in the charger before a long take: filming keeps the screen and the camera busy.") {
                StatusValue(lamp: studio.power.pluggedIn ? .ok : .warn,
                            text: studio.power.pluggedIn ? "Plugged in" : "Battery\(studio.power.percent.map { " \($0)%" } ?? "")")
            }
            SettingRow("Low Power Mode", "Slows the Mac to save battery, and the camera then freezes once the screen is shared. Keep it off while filming: System Settings, Battery.") {
                StatusValue(lamp: studio.power.lowPower ? .warn : .ok, text: studio.power.lowPower ? "On" : "Off")
            }
            SettingRow("Light mode",
                       "Records the camera and the screen at 1080p, 30 frames a second, and looks for your face less often, so a slower Mac keeps up. Automatic turns it on for Intel Macs, Macs with 8 GB of memory or less, and in Low Power Mode.") {
                Segments(choices: [("Automatic", LightMode.automatic), ("On", .on), ("Off", .off)], selected: studio.lightMode) { studio.lightMode = $0 }
                    .disabled(studio.isBusy)
            } below: {
                Text(studio.isBusy ? "Light mode can be changed once this take has stopped." : studio.lightNote).note()
            }
        }
    }
}

// MARK: - Guides

/// How to connect a camera, for someone who has never done it: what this Mac sees right now,
/// then each way in, in numbered steps, then how to add it and what to do when it does not show.
private struct CameraGuide: View {
    @ObservedObject var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            seen
            Method(symbol: "qrcode", title: "Your phone, over Wi-Fi",
                   why: "The quickest way in: any iPhone or Android phone, with any account. No app and no cable, only the same Wi-Fi as this Mac.", steps: [
                "Press Show the code below to film with the phone, or + Add, Add a phone with a QR code, to film another angle next to the main camera. Up to four phones can film at once, each with its own code.",
                "Point the phone's camera at the code and tap the link. The first time, it warns that the connection is not private. On an iPhone, tap Show Details, then \u{201C}visit this website\u{201D}, then Visit Website. On Android, tap Advanced, then Proceed.",
                "Pick Wide 16:9 or Tall 9:16, tap Start camera, then Allow. The picture keeps that shape however the phone turns. Put the phone in its stand, back camera facing you, and keep the page open.",
            ], after: "It records up to 1080p at 30 frames a second, timed to the Mac's mic. Keep the phone plugged in for a long take.",
                   action: studio.isBusy ? nil : ("Show the code", { studio.usePhone() }))
            Method(symbol: "iphone", title: "Your iPhone, linked by Apple",
                   why: "Apple's own link: the sharpest picture, at up to 4K. It needs the iPhone and this Mac on the same Apple Account.", steps: [
                "Use an iPhone XR or newer, with iOS 16 or later.",
                "Sign in to the same Apple Account on the iPhone and on this Mac, and turn on Wi-Fi and Bluetooth on both.",
                "On the iPhone, open Settings, General, AirPlay & Continuity (AirPlay & Handoff on older iPhones), and switch on Continuity Camera.",
                "Put the iPhone in a stand or on a tripod, sideways, with its back cameras facing you, and lock its screen.",
                "For a long take, plug it into the Mac with its cable. It charges, and the picture stays steady.",
                "In a few seconds it shows up here, with a name like \"the presenter's iPhone Camera\".",
            ])
            Method(symbol: "web.camera", title: "A USB webcam",
                   why: "Like a Logitech webcam. Plug it in and it works.", steps: [
                "Plug it into the Mac. A webcam with the old, wide USB plug needs a small USB\u{2011}C adapter.",
                "In a few seconds it shows up here. Most webcams need no software.",
                "If it does not, plug it straight into the Mac rather than a hub, or try another cable.",
            ])
            Method(symbol: "camera", title: "A real camera",
                   why: "A DSLR, mirrorless camera or camcorder gives the best picture. There are two ways in:", steps: [
                "Try a plain USB cable first, with the maker's free webcam app. Canon, Fujifilm, Nikon and Sony all have one, and some newer cameras need no app at all.",
                "If that does not work, use an HDMI to USB capture card, like the Elgato Cam Link. Camera to card with an HDMI cable, card into the Mac. Turn off the information on the camera's screen (often called clean HDMI).",
            ], after: "Either way, turn off auto power off, and run the camera from a wall plug with a mains adapter shaped like its battery (a dummy battery), as a battery may not last a whole take.")
            Method(symbol: "plus", title: "Then add it",
                   why: "Once it shows in the list at the top of this page:", steps: [
                "On the main panel, press + Add and pick it under Another camera. It records its own file next to the main camera, lined up by sound.",
                "To film with it as the main camera instead, click the Camera row and pick it there.",
            ])
            Method(symbol: "wrench.and.screwdriver", title: "If it does not show up", why: "Try these in order:", steps: [
                "Unplug it and plug it back in, or try another cable. Some USB\u{2011}C cables only charge.",
                "For an iPhone: keep it near the Mac and locked, turn off its Personal Hotspot, and try its cable.",
                "Quit other apps that may be using it, like FaceTime, Zoom or Photo Booth.",
                "Open System Settings, Privacy & Security, Camera, and check AVA Recorder is switched on.",
                "Restart the Mac.",
            ])
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    /// The cameras this Mac sees right now. It updates the moment one is plugged in.
    private var seen: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cameras this Mac sees now").engraved()
            if studio.cameras.isEmpty {
                Readout(lamp: .warn, text: "None yet. Connect one below and it appears here.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(studio.cameras, id: \.uniqueID) { device in
                        Readout(lamp: .ok, text: device.localizedName + role(device))
                    }
                }
            }
        }
    }

    private func role(_ device: AVCaptureDevice) -> String {
        if device.uniqueID == studio.cameraID { return " · main camera" }
        if studio.extraCameraIDs.contains(device.uniqueID) { return " · also recording" }
        return ""
    }
}

/// One way to connect a camera: what it is, why you would, then numbered steps.
private struct Method: View {
    var symbol: String
    var title: String
    var why: String
    var steps: [String]
    /// A tip that holds for every step, shown after them without a number.
    var after: String?
    /// One button that starts this way in, at the foot of the panel.
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.raised)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(why)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.dim)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Palette.dim)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Palette.raised))
                            Text(step)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.ink.opacity(0.9))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 42)
            }
            if let after {
                Text(after)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.dim)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 42)
            }
            if let action {
                SmallButton(title: action.title, primary: true) { action.run() }
                    .padding(.leading, 42)
                    .padding(.top, 2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.face))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline))
    }
}

// MARK: - Pieces

/// One panel of rows with hairlines between them, the same face as the panel's sources.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                    row
                }
            }
        }
        .padding(.horizontal, 18)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.face))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline))
    }
}

/// A setting: its name and one plain sentence on the left, its control on the right.
struct SettingRow<Control: View, Below: View>: View {
    var title: String
    var detail: String
    @ViewBuilder var control: Control
    @ViewBuilder var below: Below

    init(_ title: String, _ detail: String, @ViewBuilder control: () -> Control,
         @ViewBuilder below: () -> Below = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.control = control()
        self.below = below()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.dim)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 380, alignment: .leading)
                Spacer(minLength: 0)
                control
            }
            below
        }
        .padding(.vertical, 15)
    }
}

private struct EffectRow: View {
    var name: String
    var on: Bool
    var bestOff: Bool
    var what: String

    var body: some View {
        SettingRow(name, what) {
            StatusValue(lamp: on ? (bestOff ? .warn : .ok) : .off, text: on ? "On" : "Off")
        }
    }
}

private struct SidebarItem: View {
    var page: SettingsPage
    var selected: Bool
    var alert: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Palette.signal : Palette.engraved)
                    .frame(width: 18)
                Text(page.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected || hover ? Palette.ink : Palette.dim)
                Spacer(minLength: 0)
                if alert { Lamp(state: .warn, size: 6) }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Palette.raised : hover ? Palette.raised.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The app's own switch, so it looks the same in every window and in snapshots.
struct Switch: View {
    var on: Bool
    var set: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button { set(!on) } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Palette.signal : Palette.raised)
                    .overlay(Capsule().strokeBorder(on ? Color.clear : Palette.hairline))
                Circle().fill(on ? Palette.ink : Palette.dim)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: 16, height: 16)
                    .padding(3)
            }
            .frame(width: 40, height: 22)
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.18), value: on)
        }
        .buttonStyle(.plain)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Two to four choices side by side, the picked one lit.
struct Segments<Value: Equatable>: View {
    var choices: [(String, Value)]
    var selected: Value
    var pick: (Value) -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                let on = choice.1 == selected
                Button { pick(choice.1) } label: {
                    Text(choice.0)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(on ? Palette.glass : Palette.dim)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Palette.signal : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.well))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline))
        .opacity(enabled ? 1 : 0.45)
        .fixedSize()
        .animation(.easeOut(duration: 0.18), value: choices.firstIndex { $0.1 == selected })
    }
}

/// None, circle, square, oval, wide: each drawn as itself.
private struct ShapePicker: View {
    @ObservedObject var studio: Studio

    var body: some View {
        HStack(spacing: 10) {
            chip(nil)
            ForEach(BubbleShape.allCases) { chip($0) }
        }
    }

    private func chip(_ shape: BubbleShape?) -> some View {
        let on = shape == nil ? !studio.faceInVideo : studio.faceInVideo && studio.bubbleShape == shape
        return Button {
            if let shape { studio.bubbleShape = shape; studio.faceInVideo = true } else { studio.faceInVideo = false }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.well)
                    if let shape {
                        let s = shape.size
                        let k = 34 / max(s.width, s.height)
                        shape.outline(scale: k)
                            .fill(on ? Palette.signal.opacity(0.9) : Palette.dim.opacity(0.55))
                            .frame(width: s.width * k, height: s.height * k)
                    } else {
                        Image(systemName: "nosign").font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.engraved)
                    }
                }
                .frame(width: 64, height: 48)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(on ? Palette.signal : Palette.hairline, lineWidth: on ? 1.5 : 1))
                Text(shape?.title ?? "None")
                    .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Palette.ink : Palette.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SmallButton: View {
    var title: String
    var primary = false
    var action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primary ? Palette.glass : Palette.ink)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(primary ? (hover ? Palette.signalHot : Palette.signal) : (hover ? Color(hex: 0x262C29) : Palette.raised)))
                .overlay(Capsule().strokeBorder(primary ? Color.clear : Palette.hairline))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .fixedSize()
    }
}

struct StatusValue: View {
    var lamp: LampState
    var text: String

    var body: some View {
        HStack(spacing: 7) {
            Lamp(state: lamp)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink)
        }
        .fixedSize()
    }
}

/// A line of plain status, set into the face like a readout window.
struct Readout: View {
    var lamp: LampState
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Lamp(state: lamp).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.well))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
    }
}

struct ValueMenu: View {
    var value: String
    var choices: [MenuChoice]

    var body: some View {
        let face = HStack(spacing: 6) {
            Text(value).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.engraved)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.hairline))
        Group {
            if Snapshots.active {
                face
            } else {
                Menu {
                    ForEach(choices) { choice in
                        Button { choice.action() } label: {
                            if choice.selected { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
                        }
                    }
                } label: { face }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
        .fixedSize()
    }
}

struct KeyCap: View {
    var text: String

    var body: some View {
        Text(text)
            // A lone mark like ` needs to be bigger to be seen at all.
            .font(.system(size: text.count == 1 ? 18 : 13, weight: text.count == 1 ? .bold : .semibold))
            .foregroundStyle(Palette.ink)
            .frame(minWidth: 28, minHeight: 26)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.4), radius: 0.5, y: 1)
    }
}

extension Text {
    func note() -> some View {
        self.font(.system(size: 12))
            .foregroundStyle(Palette.engraved)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Bluetooth remote and clicker buttons: teach each action a button by pressing it.
private struct RemoteSettings: View {
    @ObservedObject var remote = RemoteControl.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote buttons")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.top, 10)
            Text("Pair the remote in System Settings, Bluetooth, first. Then press Set and press the button on the remote. Most camera remotes send Volume Up; presentation clickers send Page Down. During a take the button does this job instead of its usual one.")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.dim)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
            SettingsGroup {
                ForEach(RemoteAction.allCases) { action in
                    SettingRow(action.title, detail(action)) {
                        HStack(spacing: 8) {
                            if remote.learning == action {
                                SmallButton(title: "Cancel") { remote.cancelLearning() }
                            } else {
                                if let button = remote.buttons[action] {
                                    KeyCap(text: button.name)
                                    SmallButton(title: "Remove") { remote.forget(action) }
                                }
                                SmallButton(title: remote.buttons[action] == nil ? "Set" : "Change") {
                                    remote.setActive(false)
                                    remote.learn(action)
                                }
                            }
                        }
                    }
                }
            }
            if needsAccess {
                HStack(spacing: 14) {
                    Readout(lamp: .warn, text: "Volume and media buttons need Accessibility access, so the Mac does not also change the volume or play music.")
                    SmallButton(title: "Allow", primary: true) { remote.askForAccess() }
                }
            }
        }
        .onDisappear { remote.cancelLearning() }
    }

    private func detail(_ action: RemoteAction) -> String {
        if remote.learning == action {
            return remote.lastHeard ?? "Press a button on the remote now. Esc cancels."
        }
        switch action {
        case .nextLine: return "Moves the prompter on one line."
        case .previousLine: return "Moves the prompter back one line."
        case .switchView: return "Me or Screen, like the switch in the recording box."
        case .startStop: return "Starts recording when ready, and stops it during a take. While AVA Recorder is open and ready, this button does only this."
        }
    }

    /// A learned volume or media button only works once the app may watch the keyboard.
    private var needsAccess: Bool {
        !remote.trusted && remote.buttons.values.contains { if case .media = $0.kind { true } else { false } }
    }
}
