import AVFoundation
import AppKit
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
    @Published private(set) var phase: Phase = .idle
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
    /// Level lives in its own object so 15 updates a second redraw the meter, not the whole panel.
    let meter = LevelMeter()
    @Published private(set) var micHeardRecently = false
    @Published private(set) var cameraAllowed = false
    @Published private(set) var micAllowed = false
    @Published private(set) var screenAllowed = false
    @Published private(set) var power = PowerState(pluggedIn: true, percent: nil)
    @Published private(set) var freeGB: Double?
    /// macOS Reactions. With gestures on, a thumbs-up puts balloons in the camera file. Even with
    /// gestures off, Reactions being on keeps hand detection running, about 10% CPU (measured 4 Oct).
    @Published private(set) var reactionsOn = false
    @Published private(set) var gesturesOn = false
    /// Extra cameras, recorded as camera-2.mov, camera-3.mov and so on, in the order they were added.
    @Published var extraCameraIDs: [String] = UserDefaults.standard.stringArray(forKey: "extraCameras") ?? [] {
        didSet {
            if !Snapshots.active { UserDefaults.standard.set(extraCameraIDs, forKey: "extraCameras") }
            applyInputs()
        }
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
    /// Off for camera-only videos: no screen.mov, no face bubble.
    @Published var recordScreen = UserDefaults.standard.object(forKey: "recordScreen") as? Bool ?? true {
        didSet { if !Snapshots.active { UserDefaults.standard.set(recordScreen, forKey: "recordScreen") } }
    }
    /// The tick box: write the transcript and chapters after a take, or skip them for a quick one.
    @Published var writeTranscript = UserDefaults.standard.object(forKey: "writeTranscript") as? Bool ?? true {
        didSet { if !Snapshots.active { UserDefaults.standard.set(writeTranscript, forKey: "writeTranscript") } }
    }
    /// What the take in progress was started with, so changing a row mid-take changes nothing.
    @Published private(set) var takeHasScreen = true
    private var takeWantsTranscript = true
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

    let camera = CameraRecorder()
    /// The panel's camera picture, joined to the session once at boot (see PreviewLayerView).
    let mainPreview = PreviewNSView()
    private let screen = ScreenRecorder()
    private var extras: [CameraRecorder] = []
    private var extraOrder: [String] = []
    let liveFrames = LiveFrames()
    private lazy var liveServer = LiveServer(frames: liveFrames, token: liveToken)
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
    private var cardStart: CFTimeInterval = 0
    private var lastLoud: CFTimeInterval = 0
    private var lastSpaceCheck: CFTimeInterval = 0
    private var ticker: Timer?
    private var checker: Timer?
    private var appObserver: NSObjectProtocol?
    private var countdownTask: Task<Void, Never>?
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
        bootLive()
        mainPreview.preview.session = camera.session

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

    /// Only the person at the Mac can switch Reactions off. This opens the macOS Video Effects panel for it.
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
        power = Preflight.power()
        // Asking macOS for free space is surprisingly costly, so once a minute is enough.
        let now = CACurrentMediaTime()
        if freeGB == nil || now - lastSpaceCheck > 60 {
            freeGB = Preflight.freeGigabytes()
            lastSpaceCheck = now
        }
        screenAllowed = screenAllowed || CGPreflightScreenCaptureAccess()
        cameraAllowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        reactionsOn = AVCaptureDevice.reactionEffectsEnabled
        gesturesOn = AVCaptureDevice.reactionEffectGesturesEnabled
        touchUpOn = AVCaptureDevice.isStudioLightEnabled
    }

    private func refreshDevices(preferredCamera: String?, preferredMic: String?) {
        cameras = Devices.cameras()
        mics = Devices.mics()
        let cam = cameras.first(where: { $0.uniqueID == preferredCamera })?.uniqueID ?? cameras.first?.uniqueID
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
        let cam = cameraAllowed ? cameras.first { $0.uniqueID == cameraID } : nil
        let mic = micAllowed ? mics.first { $0.uniqueID == micID } : nil
        camera.use(camera: cam, mic: mic)

        // Each extra camera writes its own file with the same mic, so the finisher can line it up by sound.
        let wanted = cameraAllowed ? activeExtras : []
        if wanted.map(\.uniqueID) != extraOrder {
            for i in extras.indices {
                extras[i].release()
                liveTaps["camera-\(i + 2)"] = nil
                liveFrames.forget("camera-\(i + 2)")
            }
            extras = wanted.indices.map { i in
                let recorder = CameraRecorder()
                let tap = LiveTap(name: "camera-\(i + 2)", frames: liveFrames)
                liveTaps[tap.name] = tap
                recorder.attach(tap.output)
                return recorder
            }
            extraOrder = wanted.map(\.uniqueID)
        }
        for (recorder, device) in zip(extras, wanted) { recorder.use(camera: device, mic: mic) }
    }

    private func remember() {
        guard !Snapshots.active else { return }
        let d = UserDefaults.standard
        d.set(cameraID, forKey: "camera")
        d.set(micID, forKey: "mic")
        d.set(Int(displayID ?? 0), forKey: "display")
    }

    private func takeLevel(_ avg: Float, _ pk: Float) {
        meter.level = avg
        meter.peak = pk
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

    var currentItem: VideoItem? { queue.first { $0.id == currentID } }
    var cameraName: String? { staged?.camera ?? cameras.first { $0.uniqueID == cameraID }?.localizedName }
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
            return ["camera": "Camera", "effects": "Effects", "touchup": "Touch up", "mic": "Mic", "screen": "Record",
                    "face": "In video", "after": "After", "prompter": "Prompter", "mac": "Mac", "live": "Live"][id] ?? id
        }
    }

    var checks: [Check] {
        var out: [Check] = []
        if !cameraAllowed {
            out.append(Check(id: "camera", state: .fail, value: "Not allowed", problem: "Allow the camera in System Settings, Privacy."))
        } else if let name = cameraName {
            out.append(Check(id: "camera", state: .ok, value: touchUpOn ? "\(name) · touched up" : name))
        } else {
            out.append(Check(id: "camera", state: .warn, value: "None found", problem: "Connect the iPhone. It will appear here."))
        }

        if cameraAllowed {
            for (i, device) in activeExtras.enumerated() {
                out.append(Check(id: "camera-\(i + 2)", state: .ok, value: device.localizedName))
            }
        }

        if gesturesOn {
            out.append(Check(id: "effects", state: .warn, value: "Reactions on",
                             problem: "Turn off Reactions, or a thumbs-up puts balloons in the video. Click the Effects row."))
        } else if reactionsOn {
            out.append(Check(id: "effects", state: .warn, value: "Reactions on",
                             problem: "Turn off Reactions to save battery. Click the Effects row."))
        }

        if !micAllowed {
            out.append(Check(id: "mic", state: .fail, value: "Not allowed", problem: "Allow the microphone in System Settings, Privacy."))
        } else if let name = micName {
            out.append(Check(id: "mic", state: micHeardRecently ? .ok : .warn, value: name,
                             problem: micHeardRecently ? nil : "Say something to test the mic."))
        } else {
            out.append(Check(id: "mic", state: .fail, value: "None found", problem: "Plug the mic receiver into the Mac."))
        }

        if !recordScreen {
            out.append(Check(id: "screen", state: .ok, value: "Camera only, no screen"))
        } else if !screenAllowed {
            out.append(Check(id: "screen", state: .fail, value: "Not allowed", problem: "Click the screen row to allow screen recording."))
        } else {
            out.append(Check(id: "screen", state: display == nil ? .warn : .ok, value: display?.name ?? "No screen"))
        }
        if recordScreen {
            out.append(Check(id: "face", state: faceInVideo ? .ok : .off,
                             value: faceInVideo ? "Face, \(bubbleShape.title.lowercased())" : "Screen only"))
        }
        out.append(Check(id: "after", state: writeTranscript ? .ok : .off,
                         value: writeTranscript ? "Transcript and chapters" : "Just save the files", tick: writeTranscript))

        out.append(Check(id: "prompter", state: following ? .ok : .off, value: voiceValue))

        // Disk space and power share a row: both are about the Mac lasting the whole take.
        let spaceState: LampState = freeGB.map { $0 < 5 ? .fail : $0 < 20 ? .warn : .ok } ?? .ok
        let powerText = power.pluggedIn ? "plugged in" : "on battery" + (power.percent.map { " \($0)%" } ?? "")
        let macText = [freeGB.map { "\(Int($0)) GB free" }, powerText].compactMap { $0 }.joined(separator: " · ")
        out.append(Check(id: "mac",
                         state: spaceState == .fail ? .fail : (spaceState == .warn || !power.pluggedIn) ? .warn : .ok,
                         value: macText.prefix(1).uppercased() + macText.dropFirst(),
                         problem: spaceState != .ok ? "Free up space. A 15 minute video needs about 3 GB."
                             : power.pluggedIn ? nil : "Plug in the charger before a long take."))
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

    /// Extra cameras that are plugged in, in the order they were added. Never the main camera.
    var activeExtras: [AVCaptureDevice] {
        extraCameraIDs.compactMap { id in id == cameraID ? nil : cameras.first { $0.uniqueID == id } }
    }

    func toggleExtra(_ id: String) {
        guard !isBusy else { return }
        if let i = extraCameraIDs.firstIndex(of: id) { extraCameraIDs.remove(at: i) } else { extraCameraIDs.append(id) }
    }

    var canStart: Bool {
        switch phase {
        case .idle, .done, .failed: break
        default: return false
        }
        guard micAllowed, micID != nil else { return false }
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
        takeWantsTranscript = writeTranscript
        phase = .starting
        elapsed = 0
        cardElapsed = 0
        cardIndex = 0
        ended = false

        Task {
            do {
                var item = currentItem
                let folder = try Library.newRecordingFolder(for: &item)
                if let item, let i = queue.firstIndex(where: { $0.id == item.id }) {
                    queue[i] = item
                    try? item.script.write(to: folder.appendingPathComponent("script.md"), atomically: true, encoding: .utf8)
                }
                self.folder = folder
                camera.prepareForTake()
                extras.forEach { $0.prepareForTake() }

                if withScreen {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let choice = display ?? displays.first else { throw RecorderError("No screen to record.") }
                let filter = try makeFilter(content)

                screen.onError = { [weak self] error in
                    Task { @MainActor in self?.screenFailed(error) }
                }
                try await screen.start(filter: filter, pixelSize: choice.pixelSize,
                                       micID: micAllowed ? micID : nil,
                                       to: folder.appendingPathComponent("screen.mov"))
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

    private func makeFilter(_ content: SCShareableContent) throws -> SCContentFilter {
        guard let target = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw RecorderError("No screen to record.")
        }
        let hidden = Set([Bundle.main.bundleIdentifier ?? "inc.ava.recorder", "com.apple.notificationcenterui"])
        let excluded = content.applications.filter { hidden.contains($0.bundleIdentifier) }
        let shown = content.windows.filter { shownWindowIDs.contains($0.windowID) }
        return SCContentFilter(display: target, excludingApplications: excluded, exceptingWindows: shown)
    }

    /// Lets these windows of the app into the screen recording, or none with an empty list.
    func showInRecording(_ windowIDs: [CGWindowID]) {
        shownWindowIDs = windowIDs
        guard phase == .recording || phase == .starting else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let filter = try? makeFilter(content) else { return }
            try? await screen.update(filter)
            log?.write(["type": "bubble", "visible": !windowIDs.isEmpty])
        }
    }

    private func rolling(from time: CFTimeInterval) {
        guard phase == .starting, let folder else { return }
        t0 = time
        phase = .recording
        cameraWritten = (0, time)
        lastWatch = time
        cameraLostAt = nil
        log = EventLog(url: folder.appendingPathComponent("events.jsonl"), t0: time)
        let wall = ISO8601DateFormatter().string(from: Date())
        log?.write(["type": "start", "wall": wall, "title": script.title.isEmpty ? (currentItem?.title ?? "Untitled") : script.title,
                    "targetMinutes": script.targetMinutes, "camera": "camera.mov", "screen": takeHasScreen ? "screen.mov" : "",
                    "cameraName": cameraName ?? "", "micName": micName ?? "", "screenName": display?.name ?? "",
                    "extraCameras": activeExtras.prefix(extras.count).enumerated().map { ["file": "camera-\($0.offset + 2).mov", "name": $0.element.localizedName] }],
                   at: time)

        if let i = queue.firstIndex(where: { $0.id == currentID }) {
            queue[i].recordings += 1
            Library.saveQueue(queue)
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
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

        // Three seconds of head room before the first line, which also gives the editor a clean in point.
        countdownTask = Task { @MainActor in
            for n in [3, 2, 1] {
                countdown = n
                Beeps.count()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled || phase != .recording { countdown = nil; return }
            }
            countdown = nil
            Beeps.go()
            showCard(0)
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        elapsed = now - t0
        if now - lastWatch > 2 {
            lastWatch = now
            watchCamera(now)
        }
        cardElapsed = countdown == nil ? now - cardStart : 0
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
    }

    func back() {
        guard phase == .recording, countdown == nil else { return }
        if ended { showCard(cardIndex, by: "key") } else if cardIndex > 0 { showCard(cardIndex - 1, by: "key") }
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
        countdownTask?.cancel()
        countdown = nil
        PrompterKeys.shared.disable()
        stopListening()
        ticker?.invalidate()
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        log?.write(["type": "stop"])

        Task {
            let once = Once()
            let cameraError: Error? = await withCheckedContinuation { done in
                camera.onFinished = { error in if once.first() { done.resume(returning: error) } }
                camera.stopRecording()
            }
            camera.onFinished = nil
            await stopExtras()
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
    private func cameraEndedEarly(_ error: Error?) {
        guard phase == .starting else { return }
        phase = .stopping
        Task {
            await stopExtras()
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
        for recorder in extras {
            let once = Once()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                recorder.onFinished = { _ in if once.first() { done.resume() } }
                recorder.stopRecording()
            }
            recorder.onFinished = nil
        }
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
            let withScreen = canStart
            guard withScreen || (micAllowed && micID != nil) else {
                report(["ok": false, "stage": "preflight", "cgPreflight": preflight, "screenProbe": probe ?? "ok"]); return
            }
            start(withScreen: withScreen)
            var waited = 0.0
            while phase != .recording && waited < 15 {
                if case .failed(let why) = phase { report(["ok": false, "stage": "start", "reason": why]); return }
                try? await Task.sleep(nanoseconds: 200_000_000); waited += 0.2
            }
            guard phase == .recording else { report(["ok": false, "stage": "start", "reason": "timed out"]); return }
            let step = seconds / 4
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                next()
            }
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            stop()
            waited = 0
            while waited < 300 {
                switch phase {
                case .done(let folder, let note):
                    report(["ok": true, "folder": folder.path, "note": note ?? "", "screen": withScreen ? "recorded" : "skipped: \(probe ?? "")"]); return
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
        meter.level = level
        meter.peak = level + 6
        displays = [DisplayChoice(id: 1, name: "Samsung S24R35A", pixelSize: CGSize(width: 1920, height: 1080), builtIn: false)]
        displayID = 1
        if mic != nil { micID = "staged" }
        followVoice = true
        voice = .ready
        freeGB = 212
        power = PowerState(pluggedIn: true, percent: 86)
        liveMode = .wifi
        faceInVideo = true
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

    func stageReactions(_ on: Bool) {
        reactionsOn = on
        gesturesOn = on
    }

    func stageVoice(spoken: Int, hearing: Bool) {
        spokenWords = spoken
        self.hearing = hearing
    }
}

final class LevelMeter: ObservableObject {
    @Published var level: Float = -160
    @Published var peak: Float = -160
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
        liveFrames.onWake = { [weak self] name in
            Task { @MainActor in self?.liveTaps[name]?.wake() }
        }
        let tap = LiveTap(name: "camera", frames: liveFrames)
        liveTaps[tap.name] = tap
        camera.attach(tap.output)
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
            for (i, device) in activeExtras.enumerated() {
                streams.append(["id": "camera-\(i + 2)", "kind": "Camera \(i + 2)", "label": device.localizedName])
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
        let object: [String: Any] = [
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
