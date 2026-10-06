import AVFoundation
import CoreAudio
import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

/// Everything the panel and the prompter show, and the one place that starts and stops a take.
@MainActor
final class Studio: ObservableObject {
    static let shared = Studio()

    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
        case finishing(step: String, progress: Double)
        case done(folder: URL, note: String?)
        case failed(String)
    }

    // Take state
    @Published private(set) var phase: Phase = .idle {
        didSet { updateRemote(); restCheck() }
    }
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var cardElapsed: TimeInterval = 0
    @Published private(set) var cardIndex = 0
    @Published private(set) var countdown: Int?
    @Published private(set) var ended = false

    // Queue
    @Published private(set) var queue: [VideoItem] = []
    @Published var currentID: UUID? { didSet { loadScript() } }
    @Published private(set) var script = Script.empty

    // Inputs
    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var mics: [AVCaptureDevice] = []
    @Published private(set) var displays: [DisplayChoice] = []
    @Published var cameraID: String? { didSet { applyInputs(); remember() } }
    @Published var micID: String? { didSet { applyInputs(); remember() } }
    @Published var displayID: CGDirectDisplayID? { didSet { remember(); onDisplaysChanged?() } }

    // Checks
    /// Level lives in its own object, drawn by layers, so 15 updates a second never redraw the panel.
    let meter = LevelMeter()
    @Published private(set) var micHeardRecently = false
    @Published private(set) var cameraAllowed = false
    @Published private(set) var micAllowed = false
    @Published private(set) var screenAllowed = false
    @Published private(set) var power = PowerState(pluggedIn: true, percent: nil)
    @Published private(set) var freeGB: Double?
    /// True while the camera rests to save power, until its first picture after waking arrives.
    @Published private(set) var cameraResting = false
    /// Extra cameras, recorded as camera-2.mov, camera-3.mov and so on, in the order they were added.
    @Published var extraCameraIDs: [String] = UserDefaults.standard.stringArray(forKey: "extraCameras") ?? [] {
        didSet {
            if !Snapshots.active, !Studio.selfTesting { UserDefaults.standard.set(extraCameraIDs, forKey: "extraCameras") }
            applyInputs()
        }
    }
    /// Microphones recorded next to the main one, mic-2.m4a, mic-3.m4a and on, in the order they
    /// were added: a mic the Mac sees, by its ID, or a phone's mic (`PhoneLink.micID`).
    @Published var extraMicIDs: [String] = UserDefaults.standard.stringArray(forKey: "extraMics") ?? [] {
        didSet {
            if !Snapshots.active, !Studio.selfTesting { UserDefaults.standard.set(extraMicIDs, forKey: "extraMics") }
            if let videoMicID, !extraMicIDs.contains(videoMicID) { self.videoMicID = nil }
            applyInputs()
        }
    }
    /// The mic the finished video uses: nil for the main one, or one of `extraMicIDs`. Every mic
    /// records either way, so it can still be changed while editing.
    @Published var videoMicID: String? = UserDefaults.standard.string(forKey: "videoMic") {
        didSet { if !Snapshots.active, !Studio.selfTesting { UserDefaults.standard.set(videoMicID, forKey: "videoMic") } }
    }
    @Published var liveMode = LiveMode(rawValue: UserDefaults.standard.string(forKey: "liveMode") ?? "") ?? .off {
        didSet { applyLive() }
    }
    @Published private(set) var tunnelAddress: String?
    /// Her face in a shape that IS part of the screen recording (Nate Herk style). The face box never is.
    @Published var faceInVideo = UserDefaults.standard.bool(forKey: "faceInVideo") {
        didSet { if !Snapshots.active { UserDefaults.standard.set(faceInVideo, forKey: "faceInVideo") } }
    }
    @Published var bubbleShape = BubbleShape(rawValue: UserDefaults.standard.string(forKey: "bubbleShape") ?? "") ?? .circle {
        didSet { if !Snapshots.active { UserDefaults.standard.set(bubbleShape.rawValue, forKey: "bubbleShape") } }
    }
    /// Off for camera-first takes: the take starts with the camera only, and the screen joins
    /// when it is shared from the face box. A take that is never shared has no screen.mov.
    /// Every take starts on her face; the screen is shared when she presses Screen (4 Oct, Neel:
    /// nobody wants the screen from the first second). Only the self test starts with the screen,
    /// with AVA_SCREEN_FIRST=1.
    @Published var recordScreen = ProcessInfo.processInfo.environment["AVA_SCREEN_FIRST"] != nil
    /// The tick box: write the transcript and chapters after a take, or skip them for a quick one.
    @Published var writeTranscript = UserDefaults.standard.object(forKey: "writeTranscript") as? Bool ?? true {
        didSet { if !Snapshots.active { UserDefaults.standard.set(writeTranscript, forKey: "writeTranscript") } }
    }
    /// Also record what the Mac plays (a video, a click) as a second sound track in screen.mov.
    @Published var screenAudio = UserDefaults.standard.bool(forKey: "screenAudio") {
        didSet { if !Snapshots.active { UserDefaults.standard.set(screenAudio, forKey: "screenAudio") } }
    }
    /// Make video.mp4 after a take with a screen. Off saves time and space; the camera and screen
    /// files are kept either way.
    @Published var makeVideo = UserDefaults.standard.object(forKey: "makeVideo") as? Bool ?? true {
        didSet { if !Snapshots.active { UserDefaults.standard.set(makeVideo, forKey: "makeVideo") } }
    }
    @Published var cameraQuality = CameraQuality(rawValue: UserDefaults.standard.string(forKey: "cameraQuality") ?? "") ?? .best {
        didSet { if !Snapshots.active { UserDefaults.standard.set(cameraQuality.rawValue, forKey: "cameraQuality") }; applyInputs() }
    }
    /// 60 frames a second where the camera can, for smoother motion.
    @Published var smoothMotion = UserDefaults.standard.bool(forKey: "smoothMotion") {
        didSet { if !Snapshots.active { UserDefaults.standard.set(smoothMotion, forKey: "smoothMotion") }; applyInputs() }
    }
    @Published var lightMode = LightMode(rawValue: UserDefaults.standard.string(forKey: "lightMode") ?? "") ?? .automatic {
        didSet { if !Snapshots.active { UserDefaults.standard.set(lightMode.rawValue, forKey: "lightMode") }; applyInputs() }
    }
    /// Whether light mode is in force. Only changes between takes.
    @Published private(set) var light = false
    /// What light mode should be now. `AVA_LIGHT=on` or `off` overrides it, for tests.
    var lightWanted: Bool {
        switch LightMode(rawValue: ProcessInfo.processInfo.environment["AVA_LIGHT"] ?? "") ?? lightMode {
        case .on: true
        case .off: false
        case .automatic: Machine.modest || power.lowPower
        }
    }
    /// Why light mode is on or off right now, in a sentence.
    var lightNote: String {
        switch lightMode {
        case .on: return "On. The camera records at most 1080p, 30 frames a second."
        case .off: return "Off. The camera and screen record as sharp as they can."
        case .automatic:
            if Machine.intel { return "On now: this is an Intel Mac." }
            if Machine.memoryGB <= 8 { return "On now: this Mac has \(Machine.memoryGB) GB of memory." }
            if power.lowPower { return "On now, while Low Power Mode is on." }
            return "Off now: this Mac keeps up at full sharpness."
        }
    }
    /// What the main camera is recording right now.
    @Published private(set) var cameraFormat: CameraFormat?
    /// Each phone over Wi-Fi that is filming or has its code showing, by its number.
    @Published private(set) var phoneStates: [Int: PhoneState] = [:]
    /// Which phone over Wi-Fi is the main camera, if one is.
    var mainPhone: Int? { PhoneLink.number(of: cameraID) }
    /// A phone over Wi-Fi is the main camera.
    var usingPhone: Bool { mainPhone != nil }
    func phoneState(_ number: Int) -> PhoneState { phoneStates[number] ?? PhoneState() }
    /// Phone n is in touch: as a camera, sending pictures, standing by between takes, or resting
    /// with the rest of the camera; as a microphone only, its page is open.
    func phoneReady(_ number: Int) -> Bool {
        let state = phoneState(number)
        guard filmsWith(number) else { return state.present }
        return state.connected || (state.present && (cameraResting || state.standby))
    }

    /// Phone n films: the main camera or another angle, not only a microphone.
    func filmsWith(_ number: Int) -> Bool { mainPhone == number || activeExtras.contains { $0.phone == number } }
    /// macOS camera effects that change the picture for every app. Only the person at the Mac can
    /// switch them, in Video Effects.
    @Published private(set) var portraitOn = false
    @Published private(set) var centerStageOn = false
    /// The screen is being recorded in the take in progress: from the start, or since it was shared.
    @Published private(set) var takeHasScreen = true
    /// What the finished video shows right now. Both files keep recording either way; the finisher
    /// makes video.mp4 follow each switch with a short fade.
    enum Show: String { case camera, screen }
    @Published private(set) var showing: Show = .camera
    /// The Mac's sound in this take: on or off, and from which app (nil is every app). It starts
    /// each take from Settings and changes from the speaker button in the recording box.
    @Published private(set) var soundOn = false
    @Published private(set) var soundFrom: String?
    /// Apps that are open, to pick the sound from.
    @Published private(set) var soundApps: [SoundApp] = []
    struct SoundApp: Identifiable, Equatable {
        var id: String
        var name: String
    }
    /// What the screen recording shows by default: a whole screen or one window.
    @Published var shareTarget: ShareTarget = ShareTarget.saved() {
        didSet {
            if !Snapshots.active && !Self.selfTesting { shareTarget.save() }
            if case .screen(let id) = shareTarget, displayID != id { displayID = id }
        }
    }
    /// Show the chooser when Screen is pressed. Off shares `shareTarget` at once.
    @Published var askBeforeSharing = UserDefaults.standard.object(forKey: "askBeforeSharing") as? Bool ?? true {
        didSet { if !Snapshots.active { UserDefaults.standard.set(askBeforeSharing, forKey: "askBeforeSharing") } }
    }
    /// The share choice in one set of words everywhere: "Entire screen: Samsung S24R35A" or
    /// "Google Chrome: Seller Central".
    var shareLabel: String {
        switch shareTarget {
        case .screen(let id): "Entire screen: \((displays.first { $0.id == id } ?? display)?.name ?? "this Mac")"
        case .window: shareTarget.label
        }
    }

    /// What Share screen adds, in a phrase: "the Samsung S24R35A screen", "this Mac's screen" or
    /// "the Google Chrome window".
    var sharePhrase: String {
        switch shareTarget {
        case .screen(let id):
            guard let d = displays.first(where: { $0.id == id }) ?? display, !d.builtIn else { return "this Mac's screen" }
            return "the \(d.name) screen"
        case .window(_, let appName, _): return "the \(appName) window"
        }
    }

    /// Share screen, pressed: asks what to share first when Settings says to.
    func askToShare() {
        guard isRolling, !takeHasScreen, !sharing else { return }
        shareProblem = nil
        if askBeforeSharing { SharePicker.show(.shareNow, studio: self) } else { shareScreen() }
    }

    /// A self test changes what is shared and heard for its own take only, never the saved choices.
    static let selfTesting = CommandLine.arguments.contains("--self-test")
    /// `--self-test` with AVA_QUIET=1 runs out of sight while someone uses the Mac: no windows,
    /// no Dock icon, no beeps. Launch it with `open -g` so it never comes to the front.
    nonisolated static let quietTest = CommandLine.arguments.contains("--self-test")
        && ProcessInfo.processInfo.environment["AVA_QUIET"] != nil
    /// AVA_QUIET=draw: the previews take every picture as if they could be seen, so what showing
    /// them costs can be measured out of sight.
    nonisolated static let quietDraw = quietTest && ProcessInfo.processInfo.environment["AVA_QUIET"] == "draw"

    /// Where the Mac's sound comes from at the start of a take: one app's name, or nil for every app.
    var soundFromName: String? { Snapshots.active ? stagedSoundName : UserDefaults.standard.string(forKey: "soundFromName") }
    private var stagedSoundName: String?

    /// The Mac's sound in plain words: "the Mac's sound" or "Google Chrome's sound".
    var soundWords: String { soundFromName.map { "\($0)'s sound" } ?? "the Mac's sound" }

    /// Remembers where the Mac's sound should come from next time: one app, or every app with nil.
    func rememberSound(from id: String?, name: String?) {
        guard !Snapshots.active, !Self.selfTesting else { return }
        UserDefaults.standard.set(id, forKey: "soundFrom")
        UserDefaults.standard.set(name, forKey: "soundFromName")
        objectWillChange.send()
    }

    /// The shared window during a take, in AppKit screen coordinates; nil for a whole screen.
    @Published private(set) var sharedArea: CGRect?
    private var windowWatch: Timer?
    /// Bumped when the remote asks for the screen in a camera-first take: the face box asks first.
    @Published private(set) var shareRequest = 0
    private var remoteWatch: [AnyCancellable] = []
    /// Why sharing the screen mid-take did not work, shown in the face box.
    @Published var shareProblem: String?
    /// True while the screen recorder is starting for a mid-take share.
    /// True from a click on Share screen until the screen is recording, or has failed to.
    @Published private(set) var sharing = false
    private var takeWantsTranscript = true
    private var takeWantsVideo = true
    /// macOS Studio Light: brightens her face and softens the background, inside the camera itself.
    @Published private(set) var touchUpOn = false
    @Published private(set) var liveFailure: String?

    // Voice follow
    @Published var followVoice = UserDefaults.standard.object(forKey: "followVoice") as? Bool ?? false {
        didSet { voiceChoiceChanged() }
    }
    @Published private(set) var voice: Voice = .checking
    @Published private(set) var spokenWords = 0
    @Published private(set) var hearing = false

    // Prompter
    /// How big the prompter's words are, from 0.8 (small) to 1.6 (extra large).
    @Published var prompterSize = UserDefaults.standard.object(forKey: "prompterSize") as? Double ?? 1 {
        didSet { if !Snapshots.active { UserDefaults.standard.set(prompterSize, forKey: "prompterSize") } }
    }
    /// The script scrolls up by itself at `scrollWordsPerMinute`, like a classic teleprompter.
    @Published var autoScroll = UserDefaults.standard.bool(forKey: "autoScroll") {
        didSet { if !Snapshots.active { UserDefaults.standard.set(autoScroll, forKey: "autoScroll") } }
    }
    @Published var scrollWordsPerMinute = UserDefaults.standard.object(forKey: "scrollWordsPerMinute") as? Int ?? 140 {
        didSet { if !Snapshots.active { UserDefaults.standard.set(scrollWordsPerMinute, forKey: "scrollWordsPerMinute") } }
    }
    /// Shows the prompter strip on screen during takes. Off by default (on hold since 4 Oct).
    @Published var showPrompter = UserDefaults.standard.bool(forKey: "showPrompter") {
        didSet { if !Snapshots.active { UserDefaults.standard.set(showPrompter, forKey: "showPrompter") } }
    }
    /// Where the scrolling script was, in words, at `scrollAt`. Moves on at the scroll speed from there.
    @Published private(set) var scrollFrom: Double = 0
    @Published private(set) var scrollAt: Date?

    let camera = CameraRecorder()
    /// Copies of the camera picture for every preview on screen. See CameraFeed for why.
    let feed = CameraFeed()
    /// The panel's camera picture.
    let mainPreview = PreviewNSView()
    private let screen = ScreenRecorder()
    private var extras: [CameraRecorder] = []
    private var extraOrder: [String] = []
    /// One recorder for each extra microphone, in `activeMics` order.
    private(set) var micRecorders: [MicRecorder] = []
    private var micOrder: [String] = []
    let liveFrames = LiveFrames()
    let liveAudio = LiveAudio()
    private lazy var liveServer = LiveServer(frames: liveFrames, audio: liveAudio, token: liveToken)
    private let tunnel = Tunnel()
    private var liveTaps: [String: LiveTap] = [:]
    private var liveToken = UserDefaults.standard.string(forKey: "liveToken") ?? ""
    /// The camera watchdog: how much camera.mov held at the last look, and when that last grew.
    private var cameraWritten: (seconds: Double, at: CFTimeInterval) = (0, 0)
    private var lastWatch: CFTimeInterval = 0
    private var cameraLostAt: TimeInterval?
    private var log: EventLog?
    private var folder: URL?
    private var t0: CFTimeInterval = 0
    /// When the 3-2-1 count ended. The clock on screen counts from here, so it starts at 00:00.
    private var goAt: CFTimeInterval?
    private var cardStart: CFTimeInterval = 0
    private var lastLoud: CFTimeInterval = 0
    private var lastSpaceCheck: CFTimeInterval = 0
    /// Camera rest: whether the session is stopped, since when nobody has needed it, and since
    /// when the app has been in the background.
    private var cameraAsleep = false
    /// Keeps the camera awake regardless, while a self-test waits for its phones.
    private var holdAwake = false
    private var unneededSince: CFTimeInterval?
    private var inactiveSince: CFTimeInterval?
    private var ticker: Timer?
    private var checker: Timer?
    private var appObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var startTask: Task<Void, Never>?
    private var booted = false
    var onDisplaysChanged: (() -> Void)?
    private var staged: (camera: String?, mic: String?)?
    private var listener: Listener?
    private var follower: Follower?
    private var lastHeard: CFTimeInterval = 0

    // MARK: Boot

    func boot() {
        guard !booted else { return }
        booted = true
        if let i = CommandLine.arguments.firstIndex(of: "--camera-test"), i + 1 < CommandLine.arguments.count {
            CameraTest.run(dir: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--test-framing"), i + 2 < CommandLine.arguments.count {
            FramingTest.run(movie: URL(fileURLWithPath: CommandLine.arguments[i + 1]), out: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--remote-test"), i + 1 < CommandLine.arguments.count {
            RemoteTest.run(dir: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--screen-camera-test"), i + 1 < CommandLine.arguments.count {
            ScreenCameraTest.run(dir: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--camera-cpu-test"), i + 1 < CommandLine.arguments.count {
            CameraCPUTest.run(dir: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        try? Library.makeDirectory(Library.root)
        queue = Library.loadQueue()
        currentID = queue.first(where: { $0.recordings == 0 })?.id ?? queue.first?.id

        camera.onLevel = { [weak self] avg, pk in
            DispatchQueue.main.async { self?.takeLevel(avg, pk) }
        }
        camera.onFormat = { [weak self] format in
            DispatchQueue.main.async { self?.cameraFormat = format }
        }
        bootLive()
        // A phone's mic or mute changed: the panel shows it at once, not at its next look.
        PhoneLink.shared.onChange = { [weak self] number in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.phoneChanged(number) } }
        }
        camera.attach(feed.output)
        mainPreview.feed = feed
        feed.onSeenChange = { [weak self] in MainActor.assumeIsolated { self?.restCheck() } }
        // Opened in the background (at login, say), the app counts as away from the start.
        if !NSApp.isActive { inactiveSince = CACurrentMediaTime() }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.inactiveSince = note.name == NSApplication.didResignActiveNotification ? CACurrentMediaTime() : nil
                    self?.restCheck()
                }
            }
        }

        let defaults = UserDefaults.standard
        refreshDevices(preferredCamera: defaults.string(forKey: "camera"), preferredMic: defaults.string(forKey: "mic"))
        refreshDisplays(preferred: CGDirectDisplayID(defaults.integer(forKey: "display")))

        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDevices(preferredCamera: self?.cameraID, preferredMic: self?.micID) }
            }
        }
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays(preferred: self?.displayID) }
        }

        requestPermissions()
        checkVoice()
        runChecks()
        checker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runChecks() }
        }
        applyLive()
        bootRemote()
    }

    /// Bluetooth remote and clicker buttons, learned in Settings. They listen during a take, and
    /// while ready too when one of them starts and stops recording.
    private func bootRemote() {
        let remote = RemoteControl.shared
        remote.onAction = { [weak self] action in self?.remotePressed(action) }
        remoteWatch = [
            remote.$buttons.map { _ in () }.merge(with: remote.$learning.map { _ in () })
                .receive(on: RunLoop.main)
                .sink { [weak self] in DispatchQueue.main.async { self?.updateRemote() } },
        ]
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isRolling == true { self?.refreshSoundApps() } }
            }
        }
        // Access granted in System Settings only shows once the app looks again.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RemoteControl.shared.refreshTrust() }
        }
        updateRemote()
    }

    private func updateRemote() {
        guard booted, !Snapshots.active else { return }
        let remote = RemoteControl.shared
        guard remote.learning == nil else { return }
        var ready = false
        switch phase {
        case .idle, .done, .failed: ready = remote.buttons[.startStop] != nil
        default: break
        }
        remote.setActive(isRolling || ready)
    }

    private func remotePressed(_ action: RemoteAction) {
        switch action {
        case .nextLine: next()
        case .previousLine: back()
        case .switchView:
            guard phase == .recording else { return }
            if showing == .screen { show(.camera) } else if takeHasScreen { show(.screen) } else { shareRequest += 1 }
        case .startStop:
            if isRolling { stop() } else if canStart { start() }
        }
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            Task { @MainActor in self.cameraAllowed = ok; self.applyInputs() }
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in self.micAllowed = ok; self.applyInputs() }
        }
        screenAllowed = CGPreflightScreenCaptureAccess()
        // First launch: puts the app in the Screen Recording list and shows the system prompt.
        if !screenAllowed { screenAllowed = CGRequestScreenCaptureAccess() }
        Task { await probeScreen() }
    }

    /// Only the person at the Mac can switch camera effects. This opens the macOS Video Effects panel.
    func openVideoEffects() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }

    /// The real test: ScreenCaptureKit either lists the screens or it does not.
    /// CGPreflightScreenCaptureAccess alone has been seen to say no when access is on.
    @discardableResult
    func probeScreen() async -> String? {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            screenAllowed = true
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func askForScreenAccess() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        Task { await probeScreen() }
    }

    private func runChecks() {
        // Each of these redraws the panel when set, even to the same value, so only changes are set.
        let power = Preflight.power()
        if power != self.power { self.power = power }
        let watched = Set(phonesInUse + (PhoneCodeWindow.showing.map { [$0] } ?? []))
        if !watched.isEmpty || !phoneStates.isEmpty {
            let states = Dictionary(uniqueKeysWithValues: watched.map { ($0, PhoneLink.shared.state($0)) })
            if states != phoneStates { phoneStates = states }
        }
        // Low Power Mode came or went: light mode follows, between takes only.
        if lightWanted != light { applyInputs() }
        // Asking macOS for free space is surprisingly costly, so once a minute is enough.
        let now = CACurrentMediaTime()
        if freeGB == nil || now - lastSpaceCheck > 60 {
            let free = Preflight.freeGigabytes()
            if free != freeGB { freeGB = free }
            lastSpaceCheck = now
        }
        if !screenAllowed && CGPreflightScreenCaptureAccess() { screenAllowed = true }
        let camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if camera != cameraAllowed { cameraAllowed = camera }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if mic != micAllowed { micAllowed = mic }
        if AVCaptureDevice.isStudioLightEnabled != touchUpOn { touchUpOn.toggle() }
        if AVCaptureDevice.isPortraitEffectEnabled != portraitOn { portraitOn.toggle() }
        if AVCaptureDevice.isCenterStageEnabled != centerStageOn { centerStageOn.toggle() }
        restCheck()
    }

    private func refreshDevices(preferredCamera: String?, preferredMic: String?) {
        cameras = Devices.cameras()
        mics = Devices.mics()
        // A phone over Wi-Fi is never in the system's list, so it stays picked until changed.
        let cam = PhoneLink.number(of: preferredCamera) != nil ? preferredCamera
            : cameras.first(where: { $0.uniqueID == preferredCamera })?.uniqueID ?? cameras.first?.uniqueID
        let mic = mics.first(where: { $0.uniqueID == preferredMic })?.uniqueID ?? mics.first?.uniqueID
        if cam != cameraID { cameraID = cam }
        if mic != micID { micID = mic }
        applyInputs()
    }

    private func refreshDisplays(preferred: CGDirectDisplayID?) {
        displays = DisplayChoice.all()
        if let preferred, displays.contains(where: { $0.id == preferred }) {
            if displayID != preferred { displayID = preferred }
        } else {
            // Record the external monitor when there is one; the prompter goes on the other screen.
            displayID = displays.first(where: { !$0.builtIn })?.id ?? displays.first?.id
        }
        onDisplaysChanged?()
    }

    private func applyInputs() {
        guard !isBusy, !Snapshots.active else { return }
        let cam = cameraAllowed && !usingPhone ? cameras.first { $0.uniqueID == cameraID } : nil
        let mic = micAllowed ? mics.first { $0.uniqueID == micID } : nil
        light = lightWanted
        // Light mode keeps the camera at 1080p and 30 frames a second: 4K or 60 is 2 to 4 times
        // the pixels for the Mac to encode while it also records the screen.
        let quality: CameraQuality = light && cameraQuality != .hd ? .fullHD : cameraQuality
        camera.use(camera: cam, mic: mic, quality: quality, smooth: smoothMotion && !light, phone: mainPhone.map(PhoneLink.shared.camera))

        // Each extra camera writes its own file with the same mic, so the finisher can line it up by sound.
        let wanted = cameraAllowed ? activeExtras : []
        if wanted.map(\.id) != extraOrder {
            for i in extras.indices {
                extras[i].release()
                liveTaps["camera-\(i + 2)"] = nil
                liveFrames.forget("camera-\(i + 2)")
            }
            extras = wanted.indices.map { i in
                let recorder = CameraRecorder()
                if cameraAsleep { recorder.rest(true) }
                let tap = LiveTap(name: "camera-\(i + 2)", frames: liveFrames)
                tap.camera = recorder
                liveTaps[tap.name] = tap
                // Off until someone opens the live page; it wakes itself when asked for.
                recorder.attach(tap.output, framesOn: false)
                return recorder
            }
            extraOrder = wanted.map(\.id)
        }
        // A phone brings its own picture and takes the main camera's mic, so it opens nothing on
        // the Mac: no camera, and no second copy of the mic.
        for (recorder, extra) in zip(extras, wanted) {
            recorder.use(camera: extra.device, mic: extra.isPhone ? nil : mic, quality: light ? .fullHD : .best,
                         phone: extra.phone.map(PhoneLink.shared.camera))
        }
        camera.shareMic(with: zip(extras, wanted).filter { $0.1.isPhone }.map(\.0))

        // Each extra mic records its own file, and shows its level meanwhile.
        let mics = micAllowed ? activeMics : []
        if mics.map(\.id) != micOrder {
            micRecorders.forEach { $0.release() }
            micRecorders = mics.map { mic in
                let recorder = MicRecorder()
                if cameraAsleep { recorder.rest(true) }
                if let device = mic.device { recorder.use(.device(device)) } else if let n = mic.phone { recorder.use(.phone(PhoneLink.shared.camera(n))) }
                return recorder
            }
            micOrder = mics.map(\.id)
        }
    }

    private func remember() {
        guard !Snapshots.active, !Studio.selfTesting else { return }
        let d = UserDefaults.standard
        d.set(cameraID, forKey: "camera")
        d.set(micID, forKey: "mic")
        d.set(Int(displayID ?? 0), forKey: "display")
    }

    private func takeLevel(_ avg: Float, _ pk: Float) {
        meter.show(avg, peak: pk)
        let now = CACurrentMediaTime()
        if avg > -45 { lastLoud = now }
        let heard = now - lastLoud < 8
        if heard != micHeardRecently { micHeardRecently = heard }
    }

    // MARK: Derived

    var isBusy: Bool {
        switch phase {
        case .starting, .recording, .stopping: true
        default: false
        }
    }

    var isRolling: Bool { phase == .recording }

    /// The 3, 2, 1 before a take, which the record button can still call off.
    var countingIn: Bool { phase == .starting && countdown != nil }

    /// The recorder window steps aside for the small recording box only while the screen is
    /// recorded, or about to be. A take of just the camera keeps the window as it is.
    var screenInTake: Bool {
        guard countdown == nil, takeHasScreen || sharing else { return false }
        switch phase {
        case .starting, .recording, .stopping: return true
        default: return false
        }
    }

    var currentItem: VideoItem? { queue.first { $0.id == currentID } }
    var cameraName: String? {
        staged?.camera ?? (mainPhone.map { PhoneLink.name($0) } ?? cameras.first { $0.uniqueID == cameraID }?.localizedName)
    }
    var micName: String? { staged?.mic ?? mics.first { $0.uniqueID == micID }?.localizedName }
    var display: DisplayChoice? { displays.first { $0.id == displayID } }

    /// The screen the presenter reads from: any screen that is not being recorded, the built-in one first.
    var prompterScreen: NSScreen? {
        let others = displays.filter { $0.id != displayID }.sorted { $0.builtIn && !$1.builtIn }
        if let pick = others.first { return DisplayChoice.screen(for: pick.id) }
        return displayID.flatMap(DisplayChoice.screen(for:)) ?? NSScreen.main
    }

    var currentCard: Card? { script.cards.indices.contains(cardIndex) && !ended ? script.cards[cardIndex] : nil }
    var nextCard: Card? { script.cards.indices.contains(cardIndex + 1) && !ended ? script.cards[cardIndex + 1] : nil }
    var cardBudget: TimeInterval? {
        let budgets = script.budgets
        return budgets.indices.contains(cardIndex) ? budgets[cardIndex] : nil
    }

    struct Check: Identifiable {
        var id: String
        var state: LampState
        var value: String
        var problem: String?
        /// Set for a row that is a tick box.
        var tick: Bool? = nil

        var label: String {
            if id.hasPrefix("camera-") { return "Camera \(id.dropFirst(7))" }
            return ["camera": "Camera", "effects": "Effects", "touchup": "Touch up", "mic": "Mic", "screen": "Screen",
                    "face": "Face", "after": "After", "prompter": "Prompter", "mac": "Mac", "live": "Live"][id] ?? id
        }
    }

    var checks: [Check] {
        var out: [Check] = []
        if !cameraAllowed {
            out.append(Check(id: "camera", state: .fail, value: "Not allowed", problem: "Allow the camera in System Settings, Privacy."))
        } else if let n = mainPhone, !Snapshots.active {
            out.append(Check(id: "camera", state: phoneReady(n) ? .ok : .warn, value: PhoneLink.name(n),
                             problem: phoneReady(n) ? nil : "Open AVA's link on the phone and tap Start camera. The code is in Sources, Camera."))
        } else if let name = cameraName {
            out.append(Check(id: "camera", state: .ok, value: touchUpOn ? "\(name) · touched up" : name))
        } else {
            out.append(Check(id: "camera", state: .warn, value: "None found", problem: "Connect the iPhone. It will appear here."))
        }

        if cameraAllowed {
            for (i, extra) in activeExtras.enumerated() {
                let waiting = extra.phone.map { !Snapshots.active && !phoneReady($0) } ?? false
                out.append(Check(id: "camera-\(i + 2)", state: waiting ? .warn : .ok, value: extra.name,
                                 problem: waiting ? "Open AVA's link on the phone and tap Start camera. Its row in Sources shows the code again." : nil))
            }
        }

        if !micAllowed {
            out.append(Check(id: "mic", state: .fail, value: "Not allowed", problem: "Allow the microphone in System Settings, Privacy."))
        } else if let name = micName {
            out.append(Check(id: "mic", state: micHeardRecently ? .ok : .warn, value: name,
                             problem: micHeardRecently ? nil : "Say something to test the mic."))
        } else {
            out.append(Check(id: "mic", state: .fail, value: "None found", problem: "Plug the mic receiver into the Mac."))
        }

        let sound = screenAudio ? " · Mac sound" : ""
        if !recordScreen {
            let when = isRolling && takeHasScreen ? "sharing now" : "recorded once you press Share screen"
            out.append(Check(id: "screen", state: screenAllowed ? .ok : .warn, value: "\(shareLabel) · \(when)" + sound))
        } else if !screenAllowed {
            out.append(Check(id: "screen", state: .fail, value: "Not allowed", problem: "Click the screen row to allow screen recording."))
        } else {
            out.append(Check(id: "screen", state: display == nil ? .warn : .ok, value: (display?.name ?? "No screen") + sound))
        }
        out.append(Check(id: "face", state: faceInVideo ? .ok : .off,
                         value: faceInVideo ? "\(bubbleShape.title), over the screen" : "Not over the screen"))
        out.append(Check(id: "after", state: writeTranscript ? .ok : .off,
                         value: writeTranscript ? "Transcript and chapters" : "Just save the files", tick: writeTranscript))

        out.append(Check(id: "prompter", state: following ? .ok : .off, value: voiceValue))

        // Disk space and power share a row: both are about the Mac lasting the whole take.
        let spaceState: LampState = freeGB.map { $0 < 5 ? .fail : $0 < 20 ? .warn : .ok } ?? .ok
        let powerText = (power.pluggedIn ? "plugged in" : "on battery" + (power.percent.map { " \($0)%" } ?? ""))
            + (power.lowPower ? ", Low Power Mode" : "")
        let macText = [freeGB.map { "\(Int($0)) GB free" }, powerText].compactMap { $0 }.joined(separator: " · ")
        let macProblem: String? = spaceState == .fail ? "Free up space. A 15 minute video needs about 3 GB."
            : power.lowPower ? "Low Power Mode is on, so the camera freezes once the screen is shared. Plug in the charger, or turn it off in System Settings, Battery."
            : spaceState == .warn ? "Free up space. A 15 minute video needs about 3 GB."
            : power.pluggedIn ? nil : "Plug in the charger before a long take."
        out.append(Check(id: "mac",
                         state: spaceState == .fail ? .fail : (spaceState == .warn || !power.pluggedIn || power.lowPower) ? .warn : .ok,
                         value: macText.prefix(1).uppercased() + macText.dropFirst(),
                         problem: macProblem))
        out.append(liveCheck)
        return out
    }

    private var liveCheck: Check {
        if let liveFailure { return Check(id: "live", state: .fail, value: "Not working", problem: liveFailure) }
        switch liveMode {
        case .off:
            return Check(id: "live", state: .off, value: "Off")
        case .wifi:
            return Check(id: "live", state: .ok, value: "Home Wi-Fi")
        case .anywhere:
            if Tunnel.binary == nil {
                return Check(id: "live", state: .warn, value: "Not set up",
                             problem: "Watching from outside home needs cloudflared installed. Home Wi-Fi works now.")
            }
            return Check(id: "live", state: tunnelAddress == nil ? .warn : .ok, value: tunnelAddress == nil ? "Connecting" : "Anywhere")
        }
    }

    /// The one thing that needs fixing before a take, in plain words, with what fixes it. Nil when
    /// everything is ready. The panel shows only this, never a wall of rows.
    struct Attention: Equatable {
        enum Fix: Equatable { case privacy(String), screenAccess, battery, phoneCode(Int) }
        var level: LampState
        var text: String
        var fix: Fix?
        var fixTitle: String?
        var learnMore: SettingsPage?
    }

    var attention: Attention? {
        if !cameraAllowed {
            return Attention(level: .fail, text: "AVA Recorder is not allowed to use the camera yet.",
                             fix: .privacy("Privacy_Camera"), fixTitle: "Allow")
        }
        if !micAllowed {
            return Attention(level: .fail, text: "AVA Recorder is not allowed to use the microphone yet.",
                             fix: .privacy("Privacy_Microphone"), fixTitle: "Allow")
        }
        if micName == nil {
            return Attention(level: .fail, text: "No microphone found. Plug in the mic receiver or connect a Bluetooth mic.")
        }
        if !screenAllowed {
            return Attention(level: recordScreen ? .fail : .warn, text: "Screen recording is not allowed yet, so Screen cannot share during a take. Your camera still records.",
                             fix: .screenAccess, fixTitle: "Allow")
        }
        if cameraName == nil {
            return Attention(level: .warn, text: "No camera connected. Plug one in, or bring the iPhone close to the Mac.")
        }
        if let n = phoneNotReady {
            let who = phonesInUse.count > 1 ? PhoneLink.name(n) : "The phone"
            let what = filmsWith(n) ? "is not sending its picture yet. Scan its code with the phone, then tap Start camera."
                : "is not connected yet. Scan its code with the phone, then tap Start microphone."
            return Attention(level: .warn,
                             text: phoneState(n).failure ?? "\(who) \(what)",
                             fix: .phoneCode(n), fixTitle: "Show the code", learnMore: .cameraGuide)
        }
        if let freeGB, freeGB < 20 {
            return Attention(level: freeGB < 5 ? .fail : .warn,
                             text: "Only \(Int(freeGB)) GB free. A 15 minute take needs about 3 GB.", learnMore: .mac)
        }
        if let liveFailure { return Attention(level: .fail, text: liveFailure, learnMore: .live) }
        if power.lowPower {
            return Attention(level: .warn,
                             text: "Low Power Mode is on, so the camera freezes once the screen is shared. Plug in the charger, or turn Low Power Mode off.",
                             fix: .battery, fixTitle: "Open Battery settings", learnMore: .mac)
        }
        if !power.pluggedIn {
            return Attention(level: .warn, text: "On battery\(power.percent.map { " (\($0)%)" } ?? ""). Plug in the charger before a long take.",
                             learnMore: .mac)
        }
        return nil
    }

    func fix(_ fix: Attention.Fix) {
        switch fix {
        case .privacy(let anchor):
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
        case .screenAccess: askForScreenAccess()
        case .battery:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
        case .phoneCode(let n): showPhoneCode(n)
        }
    }

    /// A phone over Wi-Fi as the main camera: the link starts, and its code shows for the phone to
    /// scan. With a phone already the main camera, its code shows again.
    func usePhone() {
        guard !isBusy else { return }
        let n = mainPhone ?? freePhone ?? 1
        if mainPhone == nil { cameraID = PhoneLink.cameraID(n) }
        showPhoneCode(n)
    }

    /// Phone n's code, for its phone to scan.
    func showPhoneCode(_ number: Int) {
        PhoneLink.shared.start()
        PhoneCodeWindow.show(studio: self, phone: number)
    }

    /// How a microphone connects, so "AirPods" and "the mic receiver" are easy to tell apart.
    nonisolated static func connection(_ device: AVCaptureDevice) -> String {
        switch UInt32(bitPattern: device.transportType) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBuiltIn: "Built in"
        default: "Plugged in"
        }
    }

    /// Extra cameras that are plugged in, in the order they were added. Never the main camera.
    var activeExtras: [ExtraCamera] {
        extraCameraIDs.compactMap { id in
            if id == cameraID { return nil }
            if let n = PhoneLink.number(of: id) { return ExtraCamera(id: id, name: PhoneLink.name(n), device: nil) }
            return cameras.first { $0.uniqueID == id }.map { ExtraCamera(id: id, name: $0.localizedName, device: $0) }
        }
    }

    /// Another camera recorded next to the main one, another angle: a camera the Mac sees, or a
    /// phone over Wi-Fi.
    struct ExtraCamera: Equatable {
        var id: String
        var name: String
        /// Nil for a phone over Wi-Fi.
        var device: AVCaptureDevice?
        /// The phone's number, for a phone over Wi-Fi.
        var phone: Int? { PhoneLink.number(of: id) }
        var isPhone: Bool { phone != nil }
    }

    /// Every phone over Wi-Fi in the next take, filming or only listening, the main camera's first.
    var phonesInUse: [Int] {
        var seen = Set<Int>()
        return ((mainPhone.map { [$0] } ?? []) + activeExtras.compactMap(\.phone) + activeMics.compactMap(\.phone)).filter { seen.insert($0).inserted }
    }
    var phoneInUse: Bool { !phonesInUse.isEmpty }
    /// The lowest phone number that is not filming yet, while another phone can join.
    var freePhone: Int? { (1...PhoneLink.most).first { !phonesInUse.contains($0) } }
    /// The first phone in use that is not in touch yet.
    var phoneNotReady: Int? { Snapshots.active ? nil : phonesInUse.first { !phoneReady($0) } }

    /// + Add, with a QR code: another phone joins as another angle, recorded next to the main
    /// camera, and its code shows.
    func addPhone() {
        guard !isBusy, let n = freePhone else { return }
        let id = PhoneLink.cameraID(n)
        if !extraCameraIDs.contains(id) { extraCameraIDs.append(id) }
        showPhoneCode(n)
    }

    func toggleExtra(_ id: String) {
        guard !isBusy else { return }
        if let i = extraCameraIDs.firstIndex(of: id) { extraCameraIDs.remove(at: i) } else { extraCameraIDs.append(id) }
    }

    // MARK: More microphones

    /// Extra mics that can record now, in the order they were added. Never the main mic.
    var activeMics: [ExtraMic] {
        if Snapshots.active, let stagedMics { return stagedMics }
        return extraMicIDs.compactMap { id in
            if let n = PhoneLink.number(ofMic: id) { return ExtraMic(id: id, name: PhoneLink.name(n), device: nil) }
            guard id != micID || testSameMic, let device = mics.first(where: { $0.uniqueID == id }) else { return nil }
            return ExtraMic(id: id, name: device.localizedName, device: device)
        }
    }

    /// Another microphone recorded next to the main one: one the Mac sees, or a phone's.
    struct ExtraMic: Equatable {
        var id: String
        var name: String
        /// Nil for a phone's mic.
        var device: AVCaptureDevice?
        /// How a staged mic connects, for snapshots.
        var stagedConnection: String?
        /// The phone's number, for a phone's mic.
        var phone: Int? { PhoneLink.number(ofMic: id) }
        var isPhone: Bool { phone != nil }
        /// "USB", "Bluetooth", "Built in", or "Over Wi-Fi" for a phone's mic.
        var connection: String { device.map(Studio.connection) ?? stagedConnection ?? "Over Wi-Fi" }
    }

    private var stagedMics: [ExtraMic]?

    /// Snapshots: extra mics with these names (a phone's by its mic ID), their levels and whether each was heard.
    func stageMics(_ mics: [(id: String, name: String, level: Float)], videoMic: String? = nil) {
        stagedMics = mics.map { ExtraMic(id: $0.id, name: $0.name, device: nil, stagedConnection: PhoneLink.number(ofMic: $0.id) == nil ? "USB" : nil) }
        extraMicIDs = mics.map(\.id)
        videoMicID = videoMic
        for (i, mic) in mics.enumerated() {
            let (meter, heard) = micMeter(i)
            meter.show(mic.level, peak: mic.level + 6)
            heard.recently = mic.level > -45
        }
    }

    /// A self test may record the main mic a second time as an extra one, to try the extra mic path
    /// on a Mac with only one mic.
    private var testSameMic: Bool { Studio.selfTesting && ProcessInfo.processInfo.environment["AVA_MICS"]?.contains("same") == true }

    /// Adds a mic, or takes it off again. Taking off the video's mic gives the video the main one.
    func toggleMic(_ id: String) {
        guard !isBusy else { return }
        if let i = extraMicIDs.firstIndex(of: id) { extraMicIDs.remove(at: i) } else { extraMicIDs.append(id) }
    }

    /// Records phone n's sound too, or stops.
    func togglePhoneSound(_ number: Int) { toggleMic(PhoneLink.micID(number)) }

    /// + Add, a phone as a microphone: the next free phone joins for its sound only, and its code shows.
    func addPhoneMic() {
        guard !isBusy, let n = freePhone else { return }
        let id = PhoneLink.micID(n)
        if !extraMicIDs.contains(id) { extraMicIDs.append(id) }
        showPhoneCode(n)
    }

    /// The mic the video uses: nil for the main one.
    func useForVideo(_ id: String?) {
        guard !isBusy else { return }
        videoMicID = id.flatMap { extraMicIDs.contains($0) ? $0 : nil }
    }

    /// Extra mic i's level and whether it has been heard, or still ones for snapshots.
    func micMeter(_ i: Int) -> (meter: LevelMeter, heard: MicHeard) {
        if i < micRecorders.count { return (micRecorders[i].meter, micRecorders[i].heard) }
        while stagedMeters.count <= i { stagedMeters.append((LevelMeter(), MicHeard())) }
        return stagedMeters[i]
    }
    private var stagedMeters: [(LevelMeter, MicHeard)] = []

    /// The video's mic, if it is an extra one that can record now.
    var videoMic: ExtraMic? { activeMics.first { $0.id == videoMicID } }

    /// Mutes phone n's mic from this Mac, or unmutes it. The phone shows it and can flip it back.
    func setPhoneMuted(_ number: Int, _ on: Bool) {
        PhoneLink.shared.camera(number).setMuted(on)
        phoneChanged(number)
    }

    /// A phone's mic or mute changed: its row updates now, and a take notes it.
    private func phoneChanged(_ number: Int) {
        let state = PhoneLink.shared.state(number)
        let before = phoneStates[number]
        guard before != state else { return }
        phoneStates[number] = state
        if isRolling, let i = activeMics.firstIndex(where: { $0.phone == number }), before?.muted != state.muted {
            log?.write(["type": "mute", "file": "mic-\(i + 2).m4a", "on": state.muted, "by": state.mutedOnPhone ? "phone" : "mac"])
        }
    }

    var canStart: Bool {
        switch phase {
        case .idle, .done, .failed: break
        default: return false
        }
        guard micAllowed, micID != nil else { return false }
        if phoneNotReady != nil { return false }
        return !recordScreen || (screenAllowed && display != nil)
    }

    // MARK: Queue

    func addScript(_ text: String, name: String) {
        let parsed = Script.parse(text, fallbackTitle: name)
        let item = VideoItem(title: parsed.title, script: text)
        queue.append(item)
        Library.saveQueue(queue)
        if !isBusy { currentID = item.id }
    }

    func remove(_ id: UUID) {
        guard !(isBusy && id == currentID) else { return }
        queue.removeAll { $0.id == id }
        Library.saveQueue(queue)
        if currentID == id { currentID = queue.first?.id }
    }

    func select(_ id: UUID) {
        guard !isBusy else { return }
        currentID = id
        if case .done = phase { phase = .idle }
        if case .failed = phase { phase = .idle }
    }

    /// Moves to the next video that has not been filmed yet.
    func nextVideo() {
        let index = queue.firstIndex { $0.id == currentID } ?? -1
        let later = queue.dropFirst(index + 1).first { $0.recordings == 0 }
        currentID = (later ?? queue.first { $0.recordings == 0 })?.id ?? currentID
        phase = .idle
    }

    private func loadScript() {
        script = currentItem?.parsed ?? .empty
        cardIndex = 0
        ended = false
    }

    // MARK: Recording

    func start(withScreen requested: Bool? = nil) {
        let withScreen = requested ?? recordScreen
        let cameraOnlyOK = !withScreen && micAllowed && micID != nil && !isBusy
        guard canStart || cameraOnlyOK else { return }
        takeHasScreen = withScreen
        shareProblem = nil
        takeWantsTranscript = writeTranscript
        takeWantsVideo = makeVideo
        phase = .starting
        elapsed = 0
        cardElapsed = 0
        cardIndex = 0
        ended = false
        // The camera wakes and settles during the count, so the file opens the moment it ends.
        camera.prepareForTake()
        extras.forEach { $0.prepareForTake() }

        startTask = Task {
            // 3, 2, 1 before anything records, so the take begins clean, on the first word.
            for n in [3, 2, 1] {
                countdown = n
                Beeps.count()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled || phase != .starting { return }
            }
            countdown = nil
            do {
                var item = currentItem
                let folder = try Library.newRecordingFolder(for: &item)
                if let item, let i = queue.firstIndex(where: { $0.id == item.id }) {
                    queue[i] = item
                    try? item.script.write(to: folder.appendingPathComponent("script.md"), atomically: true, encoding: .utf8)
                }
                self.folder = folder

                if withScreen {
                await waitForStage()
                let content = try await shareableContent(for: shareTarget)
                let capture = try capture(content, shareTarget)

                screen.onError = { [weak self] error in
                    Task { @MainActor in self?.screenFailed(error) }
                }
                try await screen.start(filter: capture.filter, display: capture.display, pixelSize: capture.pixelSize,
                                       source: capture.source, micID: micAllowed ? micID : nil,
                                       to: folder.appendingPathComponent("screen.mov"))
                began(capture, shareTarget)
                await startSound()
                }

                camera.onStarted = { [weak self] time in
                    Task { @MainActor in self?.rolling(from: time) }
                }
                camera.onFinished = { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        if self.phase == .starting { self.cameraEndedEarly(error) } else { self.cameraStopped(error) }
                    }
                }
                camera.startRecording(to: folder.appendingPathComponent("camera.mov"))
                for (i, recorder) in extras.enumerated() {
                    let file = "camera-\(i + 2).mov"
                    recorder.onStarted = nil
                    recorder.onFinished = { [weak self] error in
                        Task { @MainActor in
                            self?.log?.write(["type": "camera-error", "file": file, "message": error?.localizedDescription ?? "stopped early"])
                        }
                    }
                    recorder.startRecording(to: folder.appendingPathComponent(file))
                }
                for (i, recorder) in micRecorders.enumerated() {
                    recorder.startRecording(to: folder.appendingPathComponent("mic-\(i + 2).m4a"))
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if phase == .starting { cameraEndedEarly(nil) }
            } catch {
                await screen.stop()
                phase = .failed(plain(error))
            }
        }
    }

    /// Everything on the chosen screen except this app and Notification Center, apart from any
    /// of this app's windows asked for by `showInRecording` (the face bubble).
    private var shownWindowIDs: [CGWindowID] = []

    /// What a screen recording takes in: the filter, its display, the picture size, and for one
    /// window, the part of the display the window covers.
    struct Capture {
        var filter: SCContentFilter
        var display: SCDisplay
        var pixelSize: CGSize
        /// Display points; nil for the whole screen.
        var source: CGRect?
        var windowID: CGWindowID?
        var name: String
    }

    /// The chosen screen, or the chosen window and this app's own windows over it (the stage and
    /// the bubble), cropped to the window. Throws in plain words when the window is not open.
    private func capture(_ content: SCShareableContent, _ wanted: ShareTarget) throws -> Capture {
        let ours = content.windows.filter { shownWindowIDs.contains($0.windowID) }
        switch wanted {
        case .screen(let id):
            guard let target = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first(where: { $0.displayID == displayID })
                    ?? content.displays.first else { throw RecorderError("No screen to record.") }
            let hidden = Set([Bundle.main.bundleIdentifier ?? "inc.ava.recorder", "com.apple.notificationcenterui"])
            let excluded = content.applications.filter { hidden.contains($0.bundleIdentifier) }
            let full = displays.first { $0.id == target.displayID }?.pixelSize ?? CGSize(width: target.width * 2, height: target.height * 2)
            // At most 4K, which is what YouTube shows, and 1920 in light mode, the size video.mp4
            // is made at anyway. A 5K display at full size is twice the pixels of 4K to encode.
            let k = min(1, (light ? 1920 : 3840) / max(full.width, full.height, 1))
            let size = CGSize(width: CGFloat(Int(full.width * k) & ~1), height: CGFloat(Int(full.height * k) & ~1))
            return Capture(filter: SCContentFilter(display: target, excludingApplications: excluded, exceptingWindows: ours),
                           display: target, pixelSize: size, source: nil, windowID: nil,
                           name: displays.first { $0.id == target.displayID }?.name ?? "Screen")
        case .window(let app, let appName, let title):
            guard let window = ShareTarget.find(app: app, title: title, in: content) else {
                throw RecorderError("The \(appName) window to share is not open. Open it, or choose the entire screen in Sources.")
            }
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            guard let target = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
                throw RecorderError("No screen to record.")
            }
            let source = window.frame.offsetBy(dx: -target.frame.minX, dy: -target.frame.minY)
            let scale = (displays.first { $0.id == target.displayID }?.pixelSize.width ?? target.frame.width * 2) / max(target.frame.width, 1)
            let k = min(scale, 1920 / max(source.width, 1))
            let size = CGSize(width: CGFloat(Int(source.width * k) & ~1), height: CGFloat(Int(source.height * k) & ~1))
            return Capture(filter: SCContentFilter(display: target, including: [window] + ours),
                           display: target, pixelSize: size, source: source, windowID: window.windowID,
                           name: "\(appName): \(window.title?.isEmpty == false ? window.title! : appName)")
        }
    }

    /// What is being shared in the take in progress.
    private var sharing_: ShareTarget?

    /// The AVA Recorder window is showing during the take ("Back to recorder" in the recording box).
    @Published var recorderOpen = false

    /// The app whose window is being shared in this take, by bundle id and by name; nil for a whole screen.
    var sharedApp: (id: String, name: String)? {
        guard takeHasScreen, case .window(let app, let appName, _) = sharing_ else { return nil }
        return (app, appName)
    }

    /// What can be recorded right now. A window on another desktop (its app in full screen, say)
    /// cannot be recorded from here, so its app is brought forward first and macOS moves to it.
    private func shareableContent(for wanted: ShareTarget) async throws -> SCShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard case .window(let app, _, let title) = wanted else { return content }
        let everything = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = ShareTarget.find(app: app, title: title, in: everything), !window.isOnScreen,
              let pid = window.owningApplication?.processID,
              let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return content }
        // Twice at most: if something takes the Mac back to the old desktop as it settles, once more.
        for attempt in 1...2 {
            log?.write(["type": "share-bring-forward", "app": app, "attempt": attempt])
            let open = NSWorkspace.OpenConfiguration()
            open.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: open)
            // Wait for the desktop to slide over, then a moment more for it to settle.
            for _ in 0..<20 where !Self.isOnScreen(window.windowID) {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Self.isOnScreen(window.windowID) { break }
        }
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private static func isOnScreen(_ id: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
        return (list?.first?[kCGWindowIsOnscreen as String] as? Bool) == true
    }

    /// Lets these windows of the app into the screen recording (the stage and the bubble), or none
    /// with an empty list. `bubble` says whether the face bubble is one of them, for the log.
    func showInRecording(_ windowIDs: [CGWindowID], bubble: Bool) {
        shownWindowIDs = windowIDs
        guard phase == .recording || phase == .starting else { return }
        Task {
            guard let wanted = sharing_,
                  let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let capture = try? capture(content, wanted) else { return }
            try? await screen.update(capture.filter)
            log?.write(["type": "bubble", "visible": bubble])
        }
    }

    /// Starts recording the screen in the middle of a camera-first take, into screen.mov. The
    /// finisher lines it up with the camera by sound, starting from the "screen-start" event.
    func shareScreen(_ wanted: ShareTarget? = nil) {
        guard phase == .recording, !takeHasScreen, !sharing, let folder else { return }
        let wanted = wanted ?? shareTarget
        shareProblem = nil
        sharing = true
        Task {
            defer { sharing = false }
            do {
                guard screenAllowed else {
                    throw RecorderError("Screen recording is not allowed yet. Allow AVA Recorder in System Settings, Privacy, then open the app again.")
                }
                await waitForStage()
                var capture = try capture(try await shareableContent(for: wanted), wanted)
                screen.onError = { [weak self] error in
                    Task { @MainActor in self?.screenFailed(error) }
                }
                log?.write(["type": "screen-start", "screen": "screen.mov", "screenName": capture.name, "macSound": screenAudio])
                do {
                    try await screen.start(filter: capture.filter, display: capture.display, pixelSize: capture.pixelSize,
                                           source: capture.source, micID: micAllowed ? micID : nil,
                                           to: folder.appendingPathComponent("screen.mov"))
                } catch where capture.windowID != nil && phase == .recording {
                    // The window left the screen just as recording began ("invalid parameter"):
                    // bring it back and try once more.
                    log?.write(["type": "screen-retry", "message": error.localizedDescription])
                    capture = try self.capture(try await shareableContent(for: wanted), wanted)
                    try await screen.start(filter: capture.filter, display: capture.display, pixelSize: capture.pixelSize,
                                           source: capture.source, micID: micAllowed ? micID : nil,
                                           to: folder.appendingPathComponent("screen.mov"))
                }
                guard phase == .recording else { return }
                began(capture, wanted)
                takeHasScreen = true
                await startSound()
                // Sharing is a click on Screen. screen.mov first holds a moment of her camera across
                // the screen, so the finished video can change from camera.mov to it without a
                // jump; then her camera shrinks into the bubble.
                try? await Task.sleep(nanoseconds: 600_000_000)
                if phase == .recording { show(.screen) }
            } catch {
                log?.write(["type": "screen-error", "message": error.localizedDescription])
                if phase == .recording { shareProblem = plain(error) }
            }
        }
    }

    /// One click of Me or Screen. Screen needs the screen recording: in a camera-first take the
    /// first click shares it (after the face box asks), and that switches too.
    func show(_ what: Show) {
        guard phase == .recording, what != showing, what == .camera || takeHasScreen else { return }
        showing = what
        log?.write(["type": "show", "what": what.rawValue])
    }

    // MARK: One window

    /// The screen recording has started: for one window, the stage and bubble move to it, and the
    /// recording follows the window if it is moved or resized.
    private func began(_ capture: Capture, _ wanted: ShareTarget) {
        sharing_ = wanted
        windowWatch?.invalidate()
        windowWatch = nil
        guard let id = capture.windowID, let source = capture.source else { sharedArea = nil; return }
        let origin = capture.display.frame.origin
        var last = source.offsetBy(dx: origin.x, dy: origin.y)
        sharedArea = Self.appKitRect(last)
        windowWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let frame = Self.windowFrame(id), frame != last, frame.width > 50 else { return }
                last = frame
                self.sharedArea = Self.appKitRect(frame)
                let display = capture.display.frame
                Task { try? await self.screen.move(source: frame.offsetBy(dx: -display.minX, dy: -display.minY)) }
            }
        }
    }

    /// Where a window is now, in global display coordinates (top left origin).
    private static func windowFrame(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// Global display coordinates (top left origin) to AppKit's (bottom left of the main screen).
    static func appKitRect(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: The Mac's sound

    /// The screen has started recording: its sound starts as Settings says, from the app picked last
    /// time if it is open.
    private func startSound() async {
        refreshSoundApps()
        soundOn = screenAudio
        let remembered = UserDefaults.standard.string(forKey: "soundFrom")
        soundFrom = soundApps.contains { $0.id == remembered } ? remembered : nil
        await applySound()
    }

    /// On or off, from the speaker button. Any moment of the take; nothing else stops.
    func setSound(on: Bool) {
        guard isRolling, takeHasScreen, on != soundOn else { return }
        soundOn = on
        Task { await applySound() }
    }

    /// Only this app's sound (or every app's, with nil), switched on.
    func setSoundFrom(_ id: String?) {
        guard isRolling, takeHasScreen else { return }
        soundOn = true
        soundFrom = id
        rememberSound(from: id, name: id.flatMap { id in soundApps.first { $0.id == id }?.name })
        Task { await applySound() }
    }

    private func applySound() async {
        var app: SCRunningApplication?
        if let soundFrom, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) {
            app = content.applications.first { ScreenRecorder.key($0) == soundFrom }
        }
        do {
            try await screen.setSound(on: soundOn, app: app)
        } catch {
            log?.write(["type": "screen-error", "message": "sound: \(error.localizedDescription)"])
        }
        logSound()
    }

    private func logSound(at time: CFTimeInterval = CACurrentMediaTime()) {
        let from = soundFrom.map { id in soundApps.first { $0.id == id }?.name ?? id } ?? "every app"
        log?.write(["type": "sound", "on": soundOn, "from": from], at: time)
    }

    /// Open apps a person would play sound from, by name.
    func refreshSoundApps() {
        let mine = Bundle.main.bundleIdentifier
        soundApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != mine }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return SoundApp(id: app.bundleIdentifier ?? name, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func rolling(from time: CFTimeInterval) {
        guard phase == .starting, let folder else { return }
        t0 = time
        goAt = nil
        scrollAt = nil
        scrollFrom = 0
        phase = .recording
        cameraWritten = (0, time)
        lastWatch = time
        cameraLostAt = nil
        log = EventLog(url: folder.appendingPathComponent("events.jsonl"), t0: time)
        let wall = ISO8601DateFormatter().string(from: Date())
        log?.write(["type": "start", "wall": wall, "title": script.title.isEmpty ? (currentItem?.title ?? "Untitled") : script.title,
                    "targetMinutes": script.targetMinutes, "camera": "camera.mov", "screen": takeHasScreen ? "screen.mov" : "",
                    "cameraName": cameraName ?? "", "micName": micName ?? "", "screenName": display?.name ?? "",
                    "extraCameras": activeExtras.prefix(extras.count).enumerated().map { ["file": "camera-\($0.offset + 2).mov", "name": $0.element.name] },
                    "extraMics": activeMics.prefix(micRecorders.count).enumerated().map {
                        ["file": "mic-\($0.offset + 2).m4a", "name": $0.element.name, "connection": $0.element.connection]
                    },
                    "videoMic": activeMics.prefix(micRecorders.count).firstIndex { $0.id == videoMicID }.map { "mic-\($0 + 2).m4a" } ?? ""],
                   at: time)
        // A phone's mic muted from the start says so, as later mutes do.
        for (i, mic) in activeMics.prefix(micRecorders.count).enumerated() {
            if let n = mic.phone, phoneState(n).muted {
                log?.write(["type": "mute", "file": "mic-\(i + 2).m4a", "on": true, "by": phoneState(n).mutedOnPhone ? "phone" : "mac"], at: time)
            }
        }
        showing = takeHasScreen ? .screen : .camera
        log?.write(["type": "show", "what": showing.rawValue], at: time)
        if takeHasScreen { logSound(at: time) }

        if let i = queue.firstIndex(where: { $0.id == currentID }) {
            queue[i].recordings += 1
            Library.saveQueue(queue)
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Which desktop is showing, for working out later why a shared window went off screen.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            let front = NSWorkspace.shared.frontmostApplication
            let name = front?.processIdentifier == getpid() ? "this app" : front?.localizedName ?? "?"
            Task { @MainActor in self?.log?.write(["type": "desktop", "front": name]) }
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            let name = app.localizedName ?? app.bundleIdentifier ?? "App"
            Task { @MainActor in self?.log?.write(["type": "app", "name": name]) }
        }

        PrompterKeys.shared.onNext = { [weak self] in self?.next() }
        PrompterKeys.shared.onBack = { [weak self] in self?.back() }
        PrompterKeys.shared.enable()
        startListening()

        // The count was before the file opened: the take starts on the first line. The go beep
        // says the camera is rolling, so talking can start.
        goAt = CACurrentMediaTime()
        elapsed = 0
        Beeps.go()
        showCard(0)
        if autoScroll { scrollFrom = 0; scrollAt = Date() }
    }

    // MARK: Scrolling by itself

    /// Where each line starts, in words from the top of the script.
    var cardStarts: [Int] {
        var total = 0
        return script.cards.map { card in defer { total += card.words }; return total }
    }

    /// How far the scrolling script has got, in words, at `date`.
    func scrolledWords(at date: Date) -> Double {
        guard let scrollAt else { return scrollFrom }
        return scrollFrom + max(0, date.timeIntervalSince(scrollAt)) * Double(scrollWordsPerMinute) / 60
    }

    /// Moves the current line along as the script scrolls past it.
    private func followScroll() {
        guard autoScroll, scrollAt != nil, countdown == nil, !ended, !script.cards.isEmpty else { return }
        let words = scrolledWords(at: Date())
        let starts = cardStarts
        let total = starts.last.map { $0 + (script.cards.last?.words ?? 0) } ?? 0
        if words >= Double(total) { endScript(by: "scroll"); return }
        let index = (starts.lastIndex { Double($0) <= words }) ?? 0
        if index > cardIndex { showCard(index, by: "scroll") }
    }

    /// After a key or remote press, the scroll carries on from the start of the line it moved to.
    private func rescroll() {
        guard autoScroll, scrollAt != nil else { return }
        let starts = cardStarts
        scrollFrom = ended ? Double(starts.last.map { $0 + (script.cards.last?.words ?? 0) } ?? 0)
                           : Double(starts.indices.contains(cardIndex) ? starts[cardIndex] : 0)
        scrollAt = Date()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        // Every clock on screen shows whole seconds, and each change redraws every window that
        // watches the studio, so the clocks change once a second instead of five times.
        let sinceGo = goAt.map { now - $0 } ?? 0
        if Int(sinceGo) != Int(elapsed) || sinceGo < elapsed { elapsed = sinceGo }
        if now - lastWatch > 2 {
            lastWatch = now
            watchCamera(now)
        }
        followScroll()
        let onCard = countdown == nil ? now - cardStart : 0
        if Int(onCard) != Int(cardElapsed) || onCard < cardElapsed { cardElapsed = onCard }
        if listener != nil {
            if let move = follower?.tick(at: now, loudAt: lastLoud) { voiceMove(to: move) }
            let heard = now - lastHeard < 1.2
            if hearing != heard { hearing = heard }
            syncSpoken()
        }
    }

    /// `by` is "key" or "voice" for a move, and absent for the first card.
    private func showCard(_ index: Int, by: String? = nil) {
        withAnimation(.easeOut(duration: 0.24)) {
            cardIndex = index
            ended = false
        }
        cardStart = CACurrentMediaTime()
        cardElapsed = 0
        follower?.show(index, at: cardStart)
        spokenWords = 0
        guard let card = currentCard else { return }
        var fields: [String: Any] = ["type": "card", "index": index + 1, "section": card.section, "text": card.text]
        if let by { fields["by"] = by }
        log?.write(fields)
    }

    func next() {
        guard phase == .recording, countdown == nil else { return }
        if cardIndex + 1 < script.cards.count {
            showCard(cardIndex + 1, by: "key")
        } else if !ended {
            endScript(by: "key")
        }
        rescroll()
    }

    func back() {
        guard phase == .recording, countdown == nil else { return }
        if ended { showCard(cardIndex, by: "key") } else if cardIndex > 0 { showCard(cardIndex - 1, by: "key") }
        rescroll()
    }

    private func endScript(by: String) {
        withAnimation(.easeOut(duration: 0.24)) { ended = true }
        follower?.show(script.cards.count, at: CACurrentMediaTime())
        spokenWords = 0
        log?.write(["type": "end", "by": by])
    }

    func stop(thenFinish: Bool = true) {
        guard phase == .recording || phase == .starting else { return }
        phase = .stopping
        // Every mic file ends here, though the cameras take a moment longer to close.
        let stopAt = CMClockGetTime(CMClockGetHostTimeClock())
        micRecorders.forEach { $0.end(at: stopAt) }
        windowWatch?.invalidate()
        windowWatch = nil
        sharing_ = nil
        sharedArea = nil
        countdown = nil
        PrompterKeys.shared.disable()
        stopListening()
        ticker?.invalidate()
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        log?.write(["type": "stop"])

        Task {
            let cameraError = await finishRecording(camera)
            await stopExtras()
            await stopMics()
            while sharing { try? await Task.sleep(nanoseconds: 100_000_000) }
            await screen.stop()
            liveFrames.forget("screen")
            log?.close()
            log = nil
            applyInputs()

            guard let folder else { phase = .idle; return }
            if let lost = cameraLostAt {
                cameraLostAt = nil
                let at = String(format: "%02d:%02d", Int(lost) / 60, Int(lost) % 60)
                phase = .failed("The camera stopped recording at \(at), so the take was stopped there. "
                                + "Everything up to then is in the folder. Check the camera, then press Start again.")
                return
            }
            if let cameraError {
                phase = .failed("The camera file did not close cleanly: \(cameraError.localizedDescription). The screen file is in the folder.")
                return
            }
            if thenFinish { finish(folder) } else { phase = .done(folder: folder, note: nil) }
        }
    }

    func stopForQuit(_ done: @escaping () -> Void) {
        stop(thenFinish: false)
        Task {
            while isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
            done()
        }
    }

    /// The camera file never started. Close the screen file and say so.
    /// The record button pressed again during the 3, 2, 1: nothing was recorded, so nothing is kept.
    func cancelStart() {
        guard countingIn else { return }
        startTask?.cancel()
        countdown = nil
        camera.cancelTake()
        extras.forEach { $0.cancelTake() }
        takeHasScreen = false
        phase = .idle
    }

    /// Waits, at most a second, until the stage that holds her camera is on screen and known to
    /// the recorder, so the screen recording has it from its first moment. The recorder window
    /// steps aside first, and that brings the stage up.
    private func waitForStage() async {
        var waited = 0.0
        while shownWindowIDs.isEmpty && waited < 1 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 0.05
        }
    }

    private func cameraEndedEarly(_ error: Error?) {
        guard phase == .starting else { return }
        phase = .stopping
        Task {
            // A camera file still waiting to open must not open later with nobody to stop it.
            _ = await finishRecording(camera)
            await stopExtras()
            await stopMics()
            await screen.stop()
            liveFrames.forget("screen")
            applyInputs()
            phase = .failed("The camera and mic did not start\(error.map { ": \($0.localizedDescription)" } ?? ""). Check the camera and mic rows, then try again.")
        }
    }

    /// Every 2 seconds in a take: camera.mov must keep growing. If it has not grown for 6 seconds,
    /// the camera has stopped, and filming on would only make a take with no camera in it.
    private func watchCamera(_ now: CFTimeInterval) {
        camera.written { [weak self] seconds in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                if let seconds, seconds > self.cameraWritten.seconds + 0.01 {
                    self.cameraWritten = (seconds, now)
                } else if now - self.cameraWritten.at > 6 {
                    self.cameraStopped(nil)
                }
            }
        }
    }

    private func cameraStopped(_ error: Error?) {
        guard phase == .recording else { return }
        log?.write(["type": "camera-error", "file": "camera.mov",
                    "message": error?.localizedDescription ?? "camera.mov stopped growing"])
        cameraLostAt = elapsed
        stop(thenFinish: false)
    }

    private func stopExtras() async {
        for (i, recorder) in extras.enumerated() {
            _ = await finishRecording(recorder)
            // A phone's pictures that could not go in say why, for working out a short file later.
            if !recorder.phoneDropped.isEmpty {
                log?.write(["type": "camera-dropped", "file": "camera-\(i + 2).mov", "pictures": recorder.phoneDropped])
            }
        }
    }

    /// Closes every extra mic's file, each in at most ten seconds, and notes any that went wrong.
    private func stopMics() async {
        for (i, recorder) in micRecorders.enumerated() {
            let once = Once()
            let (error, began): (Error?, CFTimeInterval?) = await withCheckedContinuation { done in
                recorder.stopRecording { error, began in if once.first() { done.resume(returning: (error, began)) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    if once.first() { done.resume(returning: (RecorderError("The mic file did not close."), nil)) }
                }
            }
            // Where the file starts on the camera's clock (it can be a moment before camera.mov),
            // for lining it up when its sound does not match the main mic's.
            if let began, let log {
                log.write(["type": "mic-start", "file": "mic-\(i + 2).m4a", "at": ((began - log.t0) * 1000).rounded() / 1000])
            }
            if let error {
                let message = (error as? RecorderError)?.message ?? error.localizedDescription
                log?.write(["type": "mic-error", "file": "mic-\(i + 2).m4a", "message": message])
            }
        }
    }

    /// Stops a recorder and waits for its file to close, at most ten seconds: a camera file that
    /// never opened may never say it closed, and a take must always end, with every other
    /// camera stopped and the app free to quit.
    private func finishRecording(_ recorder: CameraRecorder) async -> Error? {
        let once = Once()
        let error: Error? = await withCheckedContinuation { done in
            recorder.onFinished = { error in if once.first() { done.resume(returning: error) } }
            recorder.stopRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if once.first() { done.resume(returning: RecorderError("The camera file did not close.")) }
            }
        }
        recorder.onFinished = nil
        return error
    }

    private func screenFailed(_ error: Error) {
        guard phase == .recording else { return }
        log?.write(["type": "screen-error", "message": error.localizedDescription])
    }

    // MARK: Finishing

    /// Runs ava-finish: sync, transcript, chapters, retakes, report.
    private func finish(_ folder: URL) {
        guard let tool = Bundle.main.url(forAuxiliaryExecutable: "ava-finish"),
              FileManager.default.isExecutableFile(atPath: tool.path) else {
            phase = .done(folder: folder, note: "Saved. The finishing tool is missing, so there is no transcript yet.")
            return
        }
        phase = .finishing(step: "Lining up camera and screen", progress: 0.02)

        let process = Process()
        process.executableURL = tool
        process.arguments = [folder.path] + (takeWantsTranscript ? [] : ["--no-transcribe", "--no-chapters"])
            + (takeWantsVideo ? [] : ["--no-video"])
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        let reader = LineReader()

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            for line in reader.take(handle.availableData) {
                Task { @MainActor in self?.finishLine(line) }
            }
        }
        process.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                if status == 0 {
                    self.phase = .done(folder: folder, note: nil)
                } else {
                    self.phase = .done(folder: folder, note: "Saved, but finishing stopped: \(reader.failure ?? "unknown error"). The recording itself is safe.")
                }
            }
        }
        do { try process.run() } catch {
            phase = .done(folder: folder, note: "Saved. Finishing could not start: \(error.localizedDescription)")
        }
    }

    private func finishLine(_ line: String) {
        guard line.hasPrefix("STEP ") else { return }
        let parts = line.dropFirst(5).split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return }
        let fraction = parts[0].split(separator: "/").compactMap { Double($0) }
        let progress = fraction.count == 2 && fraction[1] > 0 ? fraction[0] / fraction[1] : 0.5
        phase = .finishing(step: String(parts[1]), progress: progress)
    }

    func openFolder() {
        // The take may have been renamed on the Recordings page since it finished.
        if case .done(let folder, _) = phase, FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            NSWorkspace.shared.open(Library.root)
        }
    }

    private func plain(_ error: Error) -> String {
        if let e = error as? RecorderError { return e.message }
        let text = error.localizedDescription
        if text.lowercased().contains("invalid parameter") {
            return "The window was not on screen when sharing began. Open it, then press Share screen again."
        }
        if text.lowercased().contains("declined") || text.lowercased().contains("permission") {
            return "Screen recording is not allowed yet. Allow it in System Settings, then try again."
        }
        return text
    }
}

// MARK: - Voice follow

extension Studio {
    enum Voice: Equatable {
        case checking, ready, notAllowed, unavailable
    }

    /// True while the prompter moves on by itself as the presenter speaks. The key works either way.
    var following: Bool { followVoice && voice == .ready }

    var voiceValue: String {
        guard followVoice else { return "Key only" }
        switch voice {
        case .checking, .ready: return "Follows the voice"
        case .notAllowed: return "Key only · speech not allowed"
        case .unavailable: return "Key only · voice unavailable"
        }
    }

    private func voiceChoiceChanged() {
        guard !Snapshots.active else { return }
        UserDefaults.standard.set(followVoice, forKey: "followVoice")
        checkVoice()
    }

    /// Asks for speech recognition and checks for an on-device model. Any no means key only.
    private func checkVoice() {
        guard followVoice, !Snapshots.active else { return }
        voice = .checking
        Listener.requestAccess { allowed in
            Task { @MainActor in
                guard allowed else { self.voice = .notAllowed; return }
                self.voice = await Listener.available() ? .ready : .unavailable
            }
        }
    }

    /// Listens for the whole take. Nothing the take needs waits on this.
    private func startListening() {
        guard following, !script.cards.isEmpty else { return }
        let listener = Listener()
        listener.onWords = { [weak self, weak listener] words in
            DispatchQueue.main.async { if let listener { self?.heard(words, from: listener) } }
        }
        listener.onFail = { [weak self, weak listener] message in
            DispatchQueue.main.async { if let listener { self?.listenFailed(message, from: listener) } }
        }
        self.listener = listener
        follower = Follower(cards: script.cards, title: script.title)
        Task {
            do {
                try await listener.start()
                guard self.listener === listener else { listener.stop(); return }
                camera.forwardAudio { listener.feed($0) }
            } catch {
                listenFailed(error.localizedDescription, from: listener)
            }
        }
    }

    private func stopListening() {
        camera.forwardAudio(nil)
        listener?.stop()
        listener = nil
        follower = nil
        hearing = false
        spokenWords = 0
    }

    /// Recognition stopped working: note it in the log and carry on with the key.
    private func listenFailed(_ message: String, from source: Listener) {
        guard source === listener else { return }
        log?.write(["type": "listen-error", "message": message])
        voice = .unavailable
        stopListening()
    }

    private func heard(_ words: [String], from source: Listener) {
        guard source === listener, phase == .recording else { return }
        let now = CACurrentMediaTime()
        lastHeard = now
        if !hearing { hearing = true }
        if let move = follower?.hear(words, at: now, loudAt: lastLoud) { voiceMove(to: move) }
        syncSpoken()
    }

    /// Forward only, and never during the count or after the end.
    private func voiceMove(to index: Int) {
        guard countdown == nil, !ended, index > cardIndex else { return }
        if index < script.cards.count { showCard(index, by: "voice") } else { endScript(by: "voice") }
    }

    private func syncSpoken() {
        let spoken = follower?.spoken ?? 0
        if spoken != spokenWords { spokenWords = spoken }
    }
}

// MARK: - Self test (`--self-test <seconds>`)

extension Studio {
    /// Records a short take with the real devices, finishes it, writes the outcome to
    /// /Users/Shared/AVA Recordings/.selftest.json and quits. Used to check the whole chain.
    func selfTest(seconds: Double) {
        let out = Library.root.appendingPathComponent(".selftest.json")
        func report(_ fields: [String: Any]) {
            var all = fields
            all["build"] = Bundle.main.bundleURL.path
            all["checks"] = checks.map { "\($0.id): \($0.value)\($0.problem.map { " (\($0))" } ?? "")" }
            let previews = feed.report
            all["previews"] = ["framesShown": previews.frames, "states": previews.states]
            all["drops"] = FrameDrops.report
            let face = FaceTracker.seen
            all["face"] = ["frame": "\(face.width)x\(face.height)", "looks": face.looks]
            all["light"] = light
            all["camera"] = cameraFormat?.text ?? "none"
            if let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out)
            }
            NSApp.terminate(nil)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            runChecks()
            let preflight = CGPreflightScreenCaptureAccess()
            let probe = await probeScreen()
            if let sample = try? String(contentsOfFile: "/Users/you/Youtube video recorder/Examples/sample-script.md", encoding: .utf8) {
                currentID = nil
                script = Script.parse(sample, fallbackTitle: "Self test")
            }
            // The Record row decides, unless the screen cannot be recorded at all.
            let withScreen = canStart && recordScreen
            guard canStart || (micAllowed && micID != nil) else {
                report(["ok": false, "stage": "preflight", "cgPreflight": preflight, "screenProbe": probe ?? "ok"]); return
            }
            // AVA_CAMERA=phone films with phone 1 over Wi-Fi: it waits up to a minute for its page
            // to send pictures, and writes the links it serves to .selftest-phone.txt (one a line).
            // AVA_CAMERA=phone-extra records phone 1 as another camera instead, and phones records
            // phones 1 and 2 as two more angles next to the Mac's own camera.
            // AVA_MICS adds microphones: "phones" records the filming phones' own sound too,
            // "phone-only" adds one more phone for its sound only, and "same" records the main mic
            // a second time as an extra one (the device path, on a Mac with one mic). Comma separated.
            // AVA_VIDEO_MIC=first makes the first extra mic the video's sound.
            let env = ProcessInfo.processInfo.environment
            let role = env["AVA_CAMERA"] ?? ""
            let micWords = (env["AVA_MICS"] ?? "").split(separator: ",").map(String.init)
            let filming = role == "phones" ? [1, 2] : role.hasPrefix("phone") ? [1] : []
            let listeningOnly = micWords.contains("phone-only") ? [filming.count + 1] : []
            if role == "phone" {
                cameraID = PhoneLink.cameraID(1)
            } else if role.hasPrefix("phone") {
                cameraID = cameras.first?.uniqueID
                extraCameraIDs = filming.map(PhoneLink.cameraID)
            } else if !micWords.isEmpty {
                extraCameraIDs = []
            }
            if !micWords.isEmpty {
                extraMicIDs = (micWords.contains("phones") ? filming.map(PhoneLink.micID) : []) + listeningOnly.map(PhoneLink.micID)
                    + (micWords.contains("same") ? [micID].compactMap { $0 } : [])
                if env["AVA_VIDEO_MIC"] == "first" { videoMicID = extraMicIDs.first }
            }
            let numbers = filming + listeningOnly
            if !numbers.isEmpty {
                PhoneLink.shared.start()
                let links = numbers.compactMap { PhoneLink.shared.link($0) }.joined(separator: "\n")
                try? links.write(to: Library.root.appendingPathComponent(".selftest-phone.txt"), atomically: true, encoding: .utf8)
                // The camera stays awake meanwhile: a quiet test has no window to be seen in, and a
                // resting phone sends nothing. Filming phones count once their camera is ready, and
                // phones whose sound is recorded once their mic is on.
                holdAwake = true
                let listening = Set(activeMics.compactMap(\.phone))
                func allReady() -> Bool {
                    numbers.allSatisfy { n in
                        let state = PhoneLink.shared.state(n)
                        let pictureReady = !filming.contains(n) || state.connected || state.standby
                        return pictureReady && (!listening.contains(n) || state.mic == .on || state.muted)
                    }
                }
                var waited = 0.0
                while !allReady() && waited < 60 {
                    try? await Task.sleep(nanoseconds: 500_000_000); waited += 0.5
                }
                guard allReady() else {
                    let states = numbers.map { n -> String in
                        let st = PhoneLink.shared.state(n)
                        return "\(n): present \(st.present) camera \(st.camera) standby \(st.standby) connected \(st.connected) mic \(st.mic.rawValue)"
                    }
                    report(["ok": false, "stage": "phone", "reason": "a phone's page is not ready", "phones": states]); return
                }
                phoneStates = Dictionary(uniqueKeysWithValues: numbers.map { ($0, PhoneLink.shared.state($0)) })
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            // AVA_IDLE=<seconds> waits that long, ready but not recording, so the cost of simply
            // being open can be measured.
            if let idle = ProcessInfo.processInfo.environment["AVA_IDLE"].flatMap(Double.init) {
                holdAwake = true
                try? await Task.sleep(nanoseconds: UInt64(idle * 1_000_000_000))
            }
            // AVA_REST_FIRST=1 puts the camera to rest first, so the take has to wake it.
            if ProcessInfo.processInfo.environment["AVA_REST_FIRST"] != nil {
                sleepCamera(true)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            // AVA_SHARE_WINDOW=<bundle id>|<window title> shares one window instead of the whole screen,
            // and AVA_SHARE_WINDOW=screen the whole main screen, whatever was picked last.
            if ProcessInfo.processInfo.environment["AVA_SHARE_WINDOW"] == "screen" {
                shareTarget = .screen(CGMainDisplayID())
            } else if let spec = ProcessInfo.processInfo.environment["AVA_SHARE_WINDOW"] {
                let parts = spec.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                shareTarget = .window(app: parts[0], appName: parts[0], title: parts.count > 1 ? parts[1] : "")
            }
            start(withScreen: withScreen)
            holdAwake = false
            var waited = 0.0
            while phase != .recording && waited < 15 {
                if case .failed(let why) = phase { report(["ok": false, "stage": "start", "reason": why]); return }
                try? await Task.sleep(nanoseconds: 200_000_000); waited += 0.2
            }
            guard phase == .recording else { report(["ok": false, "stage": "start", "reason": "timed out"]); return }
            // AVA_SWITCHES=4:camera,9:screen clicks Me or Screen at those seconds into the take.
            for item in (ProcessInfo.processInfo.environment["AVA_SWITCHES"] ?? "").split(separator: ",") {
                let parts = item.split(separator: ":")
                guard parts.count == 2, let at = Double(parts[0]), let what = Show(rawValue: String(parts[1])) else { continue }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(at * 1_000_000_000))
                    if what == .screen && !takeHasScreen { shareScreen() } else { show(what) }
                }
            }
            // AVA_MUTE=6:1:on,12:1:off mutes or unmutes phone 1's mic from the Mac at those seconds.
            for item in (ProcessInfo.processInfo.environment["AVA_MUTE"] ?? "").split(separator: ",") {
                let parts = item.split(separator: ":")
                guard parts.count == 3, let at = Double(parts[0]), let n = Int(parts[1]) else { continue }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(at * 1_000_000_000))
                    setPhoneMuted(n, parts[2] == "on")
                }
            }
            // AVA_SOUND=2:on,5:from:afplay,8:off switches the Mac's sound at those seconds into the take.
            for item in (ProcessInfo.processInfo.environment["AVA_SOUND"] ?? "").split(separator: ",") {
                let parts = item.split(separator: ":", maxSplits: 2).map(String.init)
                guard parts.count >= 2, let at = Double(parts[0]) else { continue }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(at * 1_000_000_000))
                    switch parts[1] {
                    case "on": setSound(on: true)
                    case "off": setSound(on: false)
                    case "from": setSoundFrom(parts.count > 2 ? parts[2] : nil)
                    default: break
                    }
                }
            }
            // AVA_RECORDER_AT=<seconds>: presses Back to recorder that far in, and says what is on screen then.
            if let at = ProcessInfo.processInfo.environment["AVA_RECORDER_AT"].flatMap(Double.init) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(at * 1_000_000_000))
                    recorderOpen = true
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    let mine = NSApp.windows.first { $0 is RecorderPanel && $0.isVisible && $0.isOnActiveSpace }
                    let owner = sharedApp.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0.id).first?.localizedName }
                    let shared = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                        .contains { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
                    log?.write(["type": "selftest-recorder", "recorderOnScreen": mine != nil, "sharedStillOnScreen": shared,
                                "front": NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"])
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    recorderOpen = false
                }
            }
            // AVA_SHARE_AT=<seconds>: a camera-first take shares the screen that far in. The log
            // says which windows were up just before and 2 seconds after.
            if let at = ProcessInfo.processInfo.environment["AVA_SHARE_AT"].flatMap(Double.init) {
                Task { @MainActor in
                    @MainActor func windows(_ when: String) {
                        let main = NSApp.windows.contains { !($0 is NSPanel) && $0.isVisible }
                        let box = NSApp.windows.contains { $0 is PrompterPanel && $0.isVisible }
                        log?.write(["type": "selftest-windows", "when": when, "recorderWindow": main, "floatingBox": box])
                    }
                    try? await Task.sleep(nanoseconds: UInt64(at * 1_000_000_000))
                    windows("before sharing")
                    shareScreen()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    windows("after sharing")
                }
            }
            let step = seconds / 4
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                next()
            }
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            let clock = elapsed
            let lamps = BreathingLampView.onScreen()
            stop()
            waited = 0
            while waited < 300 {
                switch phase {
                case .done(let folder, let note):
                    report(["ok": true, "folder": folder.path, "note": note ?? "", "clockAtStop": clock, "lampsBreathing": lamps, "screen": FileManager.default.fileExists(atPath: folder.appendingPathComponent("screen.mov").path) ? "recorded" : "none: \(probe ?? "")"]); return
                case .failed(let why):
                    report(["ok": false, "stage": "stop", "reason": why]); return
                default:
                    try? await Task.sleep(nanoseconds: 500_000_000); waited += 0.5
                }
            }
            report(["ok": false, "stage": "finish", "reason": "timed out"])
        }
    }
}

// MARK: - Staged states for design snapshots (`--snapshot <dir>`)

extension Studio {
    func stage(phase: Phase, camera: String?, mic: String?, level: Float, elapsed: TimeInterval,
               cardIndex: Int, cardElapsed: TimeInterval, countdown: Int?, screenAllowed: Bool, script: String?) {
        staged = (camera, mic)
        cameraAllowed = true
        micAllowed = true
        self.screenAllowed = screenAllowed
        micHeardRecently = level > -45
        meter.show(level, peak: level + 6)
        displays = [DisplayChoice(id: 1, name: "Samsung S24R35A", pixelSize: CGSize(width: 1920, height: 1080), builtIn: false)]
        displayID = 1
        shareTarget = .screen(1)
        if mic != nil { micID = "staged" }
        followVoice = true
        voice = .ready
        freeGB = 212
        power = PowerState(pluggedIn: true, percent: 86)
        liveMode = .wifi
        faceInVideo = true
        if camera != nil { cameraFormat = CameraFormat(width: 1920, height: 1080, fps: 30) }
        if let script {
            let item = VideoItem(title: "Sample", script: script)
            queue = [item, VideoItem(title: "Second", script: "# Inbound placement fees, explained\n- one"),
                     VideoItem(title: "Third", script: "# Stranded inventory in 10 minutes\n- one")]
            currentID = item.id
        }
        self.phase = phase
        self.elapsed = elapsed
        self.cardIndex = cardIndex
        self.cardElapsed = cardElapsed
        self.countdown = countdown
    }

    /// A camera-first take that has not shared the screen yet.
    func stageCameraFirst() {
        recordScreen = false
        takeHasScreen = false
        showing = .camera
    }

    func stageShowing(_ what: Show) {
        showing = what
    }

    func stageScroll(words: Double) {
        autoScroll = true
        scrollFrom = words
        scrollAt = Date()
    }

    /// The Mac's sound switched on in Settings, from one app picked last time (nil is every app).
    func stageSound(from name: String?) {
        screenAudio = true
        stagedSoundName = name
    }

    func stageResting() {
        cameraResting = true
    }

    func stagePhone(_ state: PhoneState, phone number: Int = 1) {
        phoneStates[number] = state
    }

    func stageVoice(spoken: Int, hearing: Bool) {
        spokenWords = spoken
        self.hearing = hearing
    }
}

final class LevelMeter: ObservableObject {
    struct Reading: Equatable {
        var level: Float = -160
        var peak: Float = -160
    }
    @Published private(set) var reading = Reading()
    var level: Float { reading.level }
    var peak: Float { reading.peak }

    /// Main thread. The meter shows the top 60 dB in at most 40 segments, so a change finer than
    /// a segment, or anywhere below the bottom, would draw the same picture: it publishes only
    /// when the picture changes, and a steady room redraws nothing.
    func show(_ level: Float, peak: Float) {
        let next = Reading(level: Self.step(level), peak: Self.step(peak))
        if next != reading { reading = next }
    }

    private static func step(_ db: Float) -> Float { db <= -60 ? -160 : (db / 1.5).rounded(.down) * 1.5 }
}

/// Whether an extra mic has heard anything louder than a murmur in the last 8 seconds. Apart from
/// its level so its row redraws only when this changes, not 15 times a second.
final class MicHeard: ObservableObject {
    @Published var recently = false
}

/// Splits the finisher's output into lines and remembers a FAIL line. Used from two threads.
final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var failed: String?

    var failure: String? { lock.withLock { failed } }

    func take(_ data: Data) -> [String] {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }
        return lock.withLock {
            buffer += text
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.hasPrefix("FAIL ") { failed = String(line.dropFirst(5)) }
                lines.append(line)
            }
            return lines
        }
    }
}

// MARK: - Camera rest

extension Studio {
    /// The camera, the mic and Apple's effects on them (Reactions, Portrait) cost about 40% of a
    /// processor core even when nobody looks: measured 5 Oct with the app open but unseen all night.
    /// So they rest once no preview has been seen, or the app has sat behind other apps for 5 seconds,
    /// for 15 seconds, and wake the moment anyone looks, a take starts or the live page asks.
    func restCheck() {
        guard booted, !Snapshots.active else { return }
        let now = CACurrentMediaTime()
        // A phone's code showing counts as looking: the phone is being set up, and should not rest
        // the moment it connects.
        // Behind other apps for 5 seconds, then the 15 below: about 20 seconds in all.
        let looking = (feed.anySeen && now - (inactiveSince ?? now) < 5) || PhoneCodeWindow.isOpen
        let watched = liveTaps.keys.contains(where: liveFrames.watching) || liveAudio.listening
        if isBusy || looking || watched || holdAwake {
            unneededSince = nil
            if cameraAsleep { sleepCamera(false) }
        } else {
            let since = unneededSince ?? now
            unneededSince = since
            if !cameraAsleep, now - since >= 15 { sleepCamera(true) }
        }
    }

    private func sleepCamera(_ asleep: Bool) {
        cameraAsleep = asleep
        if asleep {
            cameraResting = true
        } else {
            // The panel keeps saying so until a fresh picture replaces the old one.
            feed.whenNextFrame { DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { if self?.cameraAsleep == false { self?.cameraResting = false } }
            } }
        }
        camera.rest(asleep)
        extras.forEach { $0.rest(asleep) }
        micRecorders.forEach { $0.rest(asleep) }
        // A camera that never sends a picture again (unplugged while resting) must not leave the word up.
        if !asleep {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                MainActor.assumeIsolated { if self?.cameraAsleep == false { self?.cameraResting = false } }
            }
        }
    }
}

struct RecorderError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Live view

extension Studio {
    fileprivate func bootLive() {
        if liveToken.isEmpty {
            liveToken = LiveServer.newToken()
            UserDefaults.standard.set(liveToken, forKey: "liveToken")
        }
        liveServer.token = liveToken
        liveServer.status = { [weak self] in
            MainActor.assumeIsolated { self?.liveStatus() ?? Data("{}".utf8) }
        }
        liveServer.onFailure = { [weak self] reason in
            Task { @MainActor in
                self?.liveFailure = "The live view could not start (\(reason)). Quit any other copy of AVA Recorder, then pick Home Wi-Fi again."
            }
        }
        // Listen on the page hears the mic as it is recorded; the first listener wakes a resting mic.
        camera.streamAudio { [audio = liveAudio] in audio.offer($0) }
        liveAudio.onFirstListener = { [weak self] in
            Task { @MainActor in self?.restCheck() }
        }
        liveFrames.onWake = { [weak self] name in
            Task { @MainActor in
                self?.liveTaps[name]?.wake()
                self?.restCheck()
            }
        }
        let tap = LiveTap(name: "camera", frames: liveFrames)
        // Without its camera the tap could never switch itself off, and took 30 frames a second
        // all day for nothing (found by the 4 Oct audit).
        tap.camera = camera
        liveTaps[tap.name] = tap
        camera.attach(tap.output, framesOn: false)
        screen.onFrame = { [frames = liveFrames] pixels in
            frames.offer("screen", pixels, maxWidth: 1600, interval: 0.5)
        }
        tunnel.onAddress = { [weak self] address in
            Task { @MainActor in self?.tunnelAddress = address }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tunnel.stop() }
        }
    }

    fileprivate func applyLive() {
        guard booted, !Snapshots.active else { return }
        UserDefaults.standard.set(liveMode.rawValue, forKey: "liveMode")
        liveFailure = nil
        guard liveMode != .off else {
            tunnel.stop()
            tunnelAddress = nil
            liveServer.stop()
            return
        }
        do {
            try liveServer.start()
        } catch {
            liveFailure = "The live view could not start: \(error.localizedDescription)"
            return
        }
        if liveMode == .anywhere {
            tunnel.start()
        } else {
            tunnel.stop()
            tunnelAddress = nil
        }
    }

    /// The link for the page in the current mode. The Wi-Fi link stays the same; the anywhere link
    /// changes every time the tunnel starts.
    var liveLink: String? {
        switch liveMode {
        case .off: nil
        case .wifi: LiveServer.localAddress.map { "\($0)/\(liveToken)/" }
        case .anywhere: tunnelAddress.map { "\($0)/\(liveToken)/" }
        }
    }

    func copyLiveLink() {
        guard let liveLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(liveLink, forType: .string)
    }

    /// A new secret. Every link handed out before stops working.
    func newLiveLink() {
        liveToken = LiveServer.newToken()
        UserDefaults.standard.set(liveToken, forKey: "liveToken")
        liveServer.token = liveToken
        objectWillChange.send()
    }

    /// What the page shows: state, time, mic level, the pictures on offer and the checks.
    func liveStatus() -> Data {
        var name = "ready"
        var message: String?
        switch phase {
        case .idle: name = "ready"
        case .starting: name = "starting"
        case .recording: name = "recording"
        case .stopping: name = "stopping"
        case .finishing(let step, _): name = "finishing"; message = step
        case .done(_, let note): name = "done"; message = note
        case .failed(let text): name = "failed"; message = text
        }
        var streams: [[String: String]] = []
        if cameraAllowed, let cameraName {
            streams.append(["id": "camera", "kind": "Camera", "label": cameraName])
            for (i, extra) in activeExtras.enumerated() {
                streams.append(["id": "camera-\(i + 2)", "kind": "Camera \(i + 2)", "label": extra.name])
            }
        }
        if (phase == .recording || phase == .starting) && takeHasScreen {
            streams.append(["id": "screen", "kind": "Screen", "label": display?.name ?? "Screen"])
        }
        let rows: [[String: Any]] = checks.filter { $0.id != "prompter" && $0.id != "live" }.map { check in
            var row: [String: Any] = ["label": check.label, "value": check.value, "state": "\(check.state)"]
            if let problem = check.problem { row["problem"] = problem }
            return row
        }
        var line: Any = NSNull()
        if isRolling, countdown == nil, let card = currentCard {
            line = ["section": card.section, "number": cardIndex + 1, "total": script.cards.count, "text": card.text]
        }
        let object: [String: Any] = [
            "showing": isRolling ? (takeHasScreen ? showing.rawValue : "camera") : NSNull(),
            "line": line,
            "listen": micAllowed && micID != nil,
            "phase": name,
            "message": message ?? NSNull(),
            "title": script.title.isEmpty ? (currentItem?.title ?? "") : script.title,
            "elapsed": isRolling ? elapsed : 0,
            "level": Double(meter.level),
            "streams": streams,
            "checks": rows,
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

/// True the first time only, from any thread. Guards a continuation against a second resume.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func first() -> Bool {
        lock.withLock {
            defer { used = true }
            return !used
        }
    }
}
