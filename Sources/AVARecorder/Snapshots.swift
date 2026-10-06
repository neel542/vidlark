import SwiftUI

/// Renders the panel and prompter in fixed states to PNGs, for design review without screen access.
enum Snapshots {
    static var active = false

    @MainActor
    static func render(to dir: URL) {
        active = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = (try? String(contentsOfFile: "Examples/sample-script.md", encoding: .utf8)) ?? "# Sample\n- one\n- two"

        func panel(_ name: String, _ setup: (Studio) -> Void) {
            let s = Studio()
            setup(s)
            write(PanelView(studio: s).preferredColorScheme(.dark), size: CGSize(width: 400, height: 769), to: dir.appendingPathComponent("panel-\(name).png"))
        }
        func prompter(_ name: String, _ setup: (Studio) -> Void) {
            let s = Studio()
            setup(s)
            // The strip grows with the text size, as the real one does.
            let height = (230 * s.prompterSize).rounded()
            write(PrompterView(studio: s).frame(width: 920, height: height), size: CGSize(width: 920, height: height),
                  to: dir.appendingPathComponent("prompter-\(name).png"))
        }

        panel("ready") { $0.stage(phase: .idle, camera: "iPhone Camera", mic: "Wireless Mic Rx", level: -24, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script) }
        // A take of just the camera: the window stays, with Share screen in it.
        panel("recording") {
            $0.stage(phase: .recording, camera: "iPhone Camera", mic: "Wireless Mic Rx", level: -14, elapsed: 462, cardIndex: 5, cardElapsed: 41, countdown: nil, screenAllowed: true, script: script)
            $0.stageCameraFirst()
        }
        panel("countdown") { $0.stage(phase: .starting, camera: "iPhone Camera", mic: "Wireless Mic Rx", level: -24, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: 2, screenAllowed: true, script: script) }
        panel("finishing") { $0.stage(phase: .finishing(step: "Writing the transcript", progress: 0.5), camera: "iPhone Camera", mic: "Wireless Mic Rx", level: -60, elapsed: 905, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script) }
        panel("resting") {
            $0.stage(phase: .idle, camera: "MacBook Air Camera", mic: "MacBook Air Microphone", level: -60, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script)
            $0.stageResting()
        }
        panel("sound") {
            $0.stage(phase: .idle, camera: "iPhone Camera", mic: "Wireless Mic Rx", level: -24, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script)
            $0.stageSound(from: "Google Chrome")
        }
        // Three angles at once: the main camera, then two phones, one wide and one tall.
        panel("angles") {
            $0.stage(phase: .idle, camera: "MacBook Air Camera", mic: "Wireless Mic Rx", level: -24, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script)
            $0.extraCameraIDs = [PhoneLink.cameraID(1), PhoneLink.cameraID(2)]
            $0.stagePhone(PhoneState(serving: true, present: true, connected: true, width: 1920, height: 1080, fps: 30), phone: 1)
            $0.stagePhone(PhoneState(serving: true, present: true, connected: true, width: 1080, height: 1920, fps: 30), phone: 2)
        }
        panel("not-ready") { $0.stage(phase: .idle, camera: nil, mic: "MacBook Air Microphone", level: -70, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: false, script: nil) }
        panel("done") { $0.stage(phase: .done(folder: URL(fileURLWithPath: "/tmp"), note: nil), camera: "iPhone Camera", mic: "Wireless Mic Rx", level: -50, elapsed: 905, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script) }

        func wide(_ name: String, _ setup: (Studio) -> Void) {
            let s = Studio()
            setup(s)
            write(PanelView(studio: s).preferredColorScheme(.dark), size: CGSize(width: 1512, height: 945), to: dir.appendingPathComponent("wide-\(name).png"))
        }
        wide("ready") { $0.stage(phase: .idle, camera: "iPhone Camera", mic: "Wireless Mic Rx", level: -24, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script) }
        wide("recording") {
            $0.stage(phase: .recording, camera: "iPhone Camera", mic: "Wireless Mic Rx", level: -14, elapsed: 462, cardIndex: 5, cardElapsed: 41, countdown: nil, screenAllowed: true, script: script)
            $0.stageCameraFirst()
        }

        for (name, open, showing) in [("pill-open", true, Studio.Show.screen), ("pill-closed", false, .screen), ("pill-me", true, .camera)] {
            let s = Studio()
            s.stage(phase: .recording, camera: "x", mic: "x", level: -18, elapsed: 312, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: nil)
            s.stageShowing(showing)
            let state = PillState()
            state.expanded = open
            // Closed, the box still holds the switch, the Mac sound row and the controls.
            let size = open ? CGSize(width: 290, height: 390) : CGSize(width: 290, height: 170)
            write(RecordingPillView(studio: s, state: state, tracker: FaceTracker(), preview: ZoomPreviewNSView()), size: size,
                  to: dir.appendingPathComponent("\(name).png"))
        }
        for (name, showing) in [("box-screen", Studio.Show.screen), ("box-me", .camera)] {
            // The face out of the video, so the box holds the face picture while the screen shows.
            let s = Studio()
            s.stage(phase: .recording, camera: "x", mic: "x", level: -18, elapsed: 312, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: nil)
            s.faceInVideo = false
            s.stageShowing(showing)
            let state = PillState()
            state.expanded = true
            write(RecordingPillView(studio: s, state: state, tracker: FaceTracker(), preview: ZoomPreviewNSView()), size: CGSize(width: 290, height: 440),
                  to: dir.appendingPathComponent("\(name).png"))
        }
        do {
            // A camera-first take with the "Share your screen?" card open.
            let s = Studio()
            s.stage(phase: .recording, camera: "x", mic: "x", level: -18, elapsed: 74, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: nil)
            s.stageCameraFirst()
            let state = PillState()
            state.expanded = true
            state.askingToShare = true
            write(RecordingPillView(studio: s, state: state, tracker: FaceTracker(), preview: ZoomPreviewNSView()), size: CGSize(width: 290, height: 570),
                  to: dir.appendingPathComponent("pill-share.png"))
        }
        UserDefaults.standard.removeObject(forKey: "faceBoxOpen")

        for shape in BubbleShape.allCases {
            let s = Studio()
            s.bubbleShape = shape
            write(FaceBubbleView(preview: ZoomPreviewNSView(), studio: s, tracker: FaceTracker()).background(Color(hex: 0x5A6E8C)),
                  size: CGSize(width: shape.size.width + 28, height: shape.size.height + 28),
                  to: dir.appendingPathComponent("bubble-\(shape.rawValue).png"))
        }

        for page in SettingsPage.allCases {
            let s = Studio()
            s.stage(phase: .idle, camera: "iPhone Camera", mic: "Wireless Mic Rx", level: -24, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: nil)
            if page == .video { s.stageSound(from: "Google Chrome") }
            if page == .prompter { s.autoScroll = true }
            let selection = SettingsSelection()
            selection.current = page
            // Taller than the real window, which scrolls, so each whole page is in the picture.
            write(SettingsView(studio: s, selection: selection).preferredColorScheme(.dark), size: CGSize(width: 920, height: page == .cameraGuide ? 1900 : 1000),
                  to: dir.appendingPathComponent("settings-\(page.rawValue).png"))
        }

        // A phone's code window, waiting and connected, and a second phone's, filming tall.
        for (name, phone, state) in [("waiting", 1, PhoneState(serving: true)),
                                     ("connected", 1, PhoneState(serving: true, present: true, connected: true, width: 1920, height: 1080, fps: 30)),
                                     ("second", 2, PhoneState(serving: true, present: true, connected: true, width: 1080, height: 1920, fps: 30))] {
            let s = Studio()
            if phone > 1 { s.extraCameraIDs = [PhoneLink.cameraID(phone)] }
            s.stagePhone(state, phone: phone)
            write(PhoneCodeView(studio: s, phone: phone).preferredColorScheme(.dark), size: CGSize(width: 740, height: 500),
                  to: dir.appendingPathComponent("phone-code-\(name).png"))
        }

        prompter("waiting") { $0.stage(phase: .idle, camera: "x", mic: "x", level: -30, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script) }
        prompter("countdown") { $0.stage(phase: .recording, camera: "x", mic: "x", level: -30, elapsed: 1, cardIndex: 0, cardElapsed: 0, countdown: 2, screenAllowed: true, script: script) }
        prompter("hook") { $0.stage(phase: .recording, camera: "x", mic: "x", level: -30, elapsed: 8, cardIndex: 0, cardElapsed: 6, countdown: nil, screenAllowed: true, script: script) }
        prompter("following") {
            $0.stage(phase: .recording, camera: "x", mic: "x", level: -30, elapsed: 9, cardIndex: 0, cardElapsed: 5, countdown: nil, screenAllowed: true, script: script)
            $0.stageVoice(spoken: 10, hearing: true)
        }
        prompter("scrolling") {
            $0.stage(phase: .recording, camera: "x", mic: "x", level: -30, elapsed: 40, cardIndex: 1, cardElapsed: 3, countdown: nil, screenAllowed: true, script: script)
            $0.stageScroll(words: 24)
        }
        do {
            let s = Studio()
            s.stage(phase: .recording, camera: "x", mic: "x", level: -18, elapsed: 74, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: nil)
            write(SharePickerView(studio: s, purpose: .shareNow, close: {}, sample: true).preferredColorScheme(.dark),
                  size: CGSize(width: 760, height: 560), to: dir.appendingPathComponent("share-picker.png"))
        }
        for (name, size) in [("large", 1.3), ("extra-large", 1.6)] {
            prompter("hook-\(name)") {
                $0.stage(phase: .recording, camera: "x", mic: "x", level: -30, elapsed: 8, cardIndex: 0, cardElapsed: 6, countdown: nil, screenAllowed: true, script: script)
                $0.prompterSize = size
            }
            prompter("scrolling-\(name)") {
                $0.stage(phase: .recording, camera: "x", mic: "x", level: -30, elapsed: 40, cardIndex: 1, cardElapsed: 3, countdown: nil, screenAllowed: true, script: script)
                $0.prompterSize = size
                $0.stageScroll(words: 24)
            }
        }
        prompter("bullet") { $0.stage(phase: .recording, camera: "x", mic: "x", level: -30, elapsed: 200, cardIndex: 3, cardElapsed: 52, countdown: nil, screenAllowed: true, script: script) }
        prompter("over") { $0.stage(phase: .recording, camera: "x", mic: "x", level: -30, elapsed: 400, cardIndex: 5, cardElapsed: 260, countdown: nil, screenAllowed: true, script: script) }

        // The Recordings page, fed staged sample takes with drawn thumbnails. Nothing on disk is read.
        func recordings(_ name: String, _ size: CGSize, _ model: @autoclosure @escaping () -> RecordingsModel, hover: Bool = false) {
            write(RecordingsView(model: model(), onClose: {}, showHover: hover).preferredColorScheme(.dark), size: size,
                  to: dir.appendingPathComponent("recordings-\(name).png"))
        }
        let roomy = CGSize(width: 1512, height: 945), narrow = CGSize(width: 400, height: 860)
        recordings("wide", roomy, .sample(), hover: true)
        recordings("narrow", narrow, .sample(notice: .init(text: "Saved a copy in Desktop", reveal: URL(fileURLWithPath: "/tmp"))))
        recordings("not-finished", roomy, .sample(filter: .unfinished))
        recordings("no-match", narrow, .sample(search: "zebra"))
        recordings("empty", roomy, .sample(empty: true))
        if let take = RecordingsModel.sample().takes.first(where: { $0.hasCamera && $0.hasScreen }) {
            for (name, size) in [("wide", roomy), ("narrow", narrow)] {
                write(TakeViewer(take: take, close: {}).preferredColorScheme(.dark), size: size,
                      to: dir.appendingPathComponent("recordings-watch-\(name).png"))
            }
        }
    }

    @MainActor
    private static func write<V: View>(_ view: V, size: CGSize, to url: URL) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { print("could not render \(url.lastPathComponent)"); return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
}
