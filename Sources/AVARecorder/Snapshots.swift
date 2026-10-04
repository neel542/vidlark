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
            write(PrompterView(studio: s).frame(width: 920, height: 230), size: CGSize(width: 920, height: 230), to: dir.appendingPathComponent("prompter-\(name).png"))
        }

        panel("ready") { $0.stage(phase: .idle, camera: "the presenter's iPhone Camera", mic: "Wireless Mic Rx", level: -24, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script) }
        panel("recording") { $0.stage(phase: .recording, camera: "the presenter's iPhone Camera", mic: "Wireless Mic Rx", level: -14, elapsed: 462, cardIndex: 5, cardElapsed: 41, countdown: nil, screenAllowed: true, script: script) }
        panel("finishing") { $0.stage(phase: .finishing(step: "Writing the transcript", progress: 0.5), camera: "the presenter's iPhone Camera", mic: "Wireless Mic Rx", level: -60, elapsed: 905, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script) }
        panel("reactions-on") {
            $0.stage(phase: .idle, camera: "the presenter's iPhone Camera", mic: "Wireless Mic Rx", level: -24, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script)
            $0.stageReactions(true)
        }
        panel("not-ready") { $0.stage(phase: .idle, camera: nil, mic: "MacBook Air Microphone", level: -70, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: false, script: nil) }
        panel("done") { $0.stage(phase: .done(folder: URL(fileURLWithPath: "/tmp"), note: nil), camera: "the presenter's iPhone Camera", mic: "Wireless Mic Rx", level: -50, elapsed: 905, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script) }

        func wide(_ name: String, _ setup: (Studio) -> Void) {
            let s = Studio()
            setup(s)
            write(PanelView(studio: s).preferredColorScheme(.dark), size: CGSize(width: 1512, height: 945), to: dir.appendingPathComponent("wide-\(name).png"))
        }
        wide("ready") { $0.stage(phase: .idle, camera: "the presenter's iPhone Camera", mic: "Wireless Mic Rx", level: -24, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script) }
        wide("recording") { $0.stage(phase: .recording, camera: "the presenter's iPhone Camera", mic: "Wireless Mic Rx", level: -14, elapsed: 462, cardIndex: 5, cardElapsed: 41, countdown: nil, screenAllowed: true, script: script) }

        for open in [true, false] {
            let s = Studio()
            s.stage(phase: .recording, camera: "x", mic: "x", level: -18, elapsed: 312, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: nil)
            let state = PillState()
            state.expanded = open
            let size = open ? CGSize(width: 290, height: 340) : CGSize(width: 290, height: 70)
            write(RecordingPillView(studio: s, state: state, tracker: FaceTracker()), size: size,
                  to: dir.appendingPathComponent(open ? "pill-open.png" : "pill-closed.png"))
        }
        UserDefaults.standard.removeObject(forKey: "faceBoxOpen")

        prompter("waiting") { $0.stage(phase: .idle, camera: "x", mic: "x", level: -30, elapsed: 0, cardIndex: 0, cardElapsed: 0, countdown: nil, screenAllowed: true, script: script) }
        prompter("countdown") { $0.stage(phase: .recording, camera: "x", mic: "x", level: -30, elapsed: 1, cardIndex: 0, cardElapsed: 0, countdown: 2, screenAllowed: true, script: script) }
        prompter("hook") { $0.stage(phase: .recording, camera: "x", mic: "x", level: -30, elapsed: 8, cardIndex: 0, cardElapsed: 6, countdown: nil, screenAllowed: true, script: script) }
        prompter("following") {
            $0.stage(phase: .recording, camera: "x", mic: "x", level: -30, elapsed: 9, cardIndex: 0, cardElapsed: 5, countdown: nil, screenAllowed: true, script: script)
            $0.stageVoice(spoken: 10, hearing: true)
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
