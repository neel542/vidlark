import AVFoundation
import AppKit
import ScreenCaptureKit
import Vision

/// `--camera-test <dir>`: records short camera files while changing the camera session the ways
/// the app can mid-take, and writes what survived to <dir>/camera-test.json. Built to find out
/// why a whole camera.mov went missing on 4 Oct.
enum CameraTest {
    private final class Sink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {}

    struct Outcome: Encodable {
        var name: String
        var fileExists: Bool
        var seconds: Double
        /// The picture alone. A file can run on with sound after its picture has stopped.
        var videoSeconds: Double = 0
        var error: String?
        var writtenSamples: [Double]
    }

    @MainActor
    static func run(dir: URL) {
        NSApp.windows.forEach { $0.orderOut(nil) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            guard let cam = AVCaptureDevice.default(for: .video), let mic = AVCaptureDevice.default(for: .audio) else {
                write(["error": "no camera or mic"], to: dir); exit(1)
            }
            var results: [Outcome] = []
            let sink = Sink()

            // Each case: (name, what to do 1.5 s in, what to do 3 s in).
            typealias Step = (CameraRecorder, AVCaptureVideoDataOutput, inout AVCaptureVideoPreviewLayer?) -> Void
            let cases: [(String, Step, Step)] = [
                ("plain", { _, _, _ in }, { _, _, _ in }),
                ("old: feed switched off and on directly",
                 { _, o, _ in o.connection(with: .video)?.isEnabled = false },
                 { _, o, _ in o.connection(with: .video)?.isEnabled = true }),
                ("old: preview added and removed",
                 { r, _, layer in layer = AVCaptureVideoPreviewLayer(session: r.session) },
                 { _, _, layer in layer?.session = nil; layer = nil }),
                ("new: feed switched through setFrames",
                 { r, o, _ in r.setFrames(o, on: false) },
                 { r, o, _ in r.setFrames(o, on: true) }),
                ("countdown beeps", { _, _, _ in Beeps.count() }, { _, _, _ in Beeps.go() }),
            ]
            // AVA_CASES=plain,beep runs only the cases whose names contain one of those words.
            let only = ProcessInfo.processInfo.environment["AVA_CASES"]?.split(separator: ",")
            for (name, first, second) in cases where only.map({ $0.contains { name.contains($0) } }) ?? true {
                NSApp.windows.forEach { $0.orderOut(nil) }
                let recorder = CameraRecorder()
                let output = AVCaptureVideoDataOutput()
                output.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "test.sink"))
                recorder.attach(output, framesOn: true)
                recorder.use(camera: cam, mic: mic)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let url = dir.appendingPathComponent(name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ":", with: "") + ".mov")
                try? FileManager.default.removeItem(at: url)
                let outcome = await take(recorder, output, url: url, first: first, second: second)
                results.append(Outcome(name: name, fileExists: outcome.exists, seconds: outcome.seconds,
                                       videoSeconds: outcome.video, error: outcome.error, writtenSamples: outcome.samples))
                recorder.release()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            // Two sessions on the same camera and mic at once, as with an extra camera.
            let main = CameraRecorder(), extra = CameraRecorder()
            main.use(camera: cam, mic: mic)
            extra.use(camera: cam, mic: mic)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let a = dir.appendingPathComponent("shared-main.mov"), b = dir.appendingPathComponent("shared-extra.mov")
            [a, b].forEach { try? FileManager.default.removeItem(at: $0) }
            main.startRecording(to: a)
            extra.startRecording(to: b)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            for r in [main, extra] {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    let once = Once()
                    r.onFinished = { _ in if once.first() { done.resume() } }
                    r.stopRecording()
                }
            }
            for (label, url) in [("shared: main", a), ("shared: extra", b)] {
                let info = await probe(url)
                results.append(Outcome(name: label + (info.audio ? " (with sound)" : " (no sound)"), fileExists: info.exists,
                                       seconds: info.seconds, error: nil, writtenSamples: []))
            }
            main.release()
            extra.release()

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try? encoder.encode(results).write(to: dir.appendingPathComponent("camera-test.json"))
            exit(0)
        }
    }

    @MainActor
    private static func take(_ recorder: CameraRecorder, _ output: AVCaptureVideoDataOutput, url: URL,
                             first: (CameraRecorder, AVCaptureVideoDataOutput, inout AVCaptureVideoPreviewLayer?) -> Void,
                             second: (CameraRecorder, AVCaptureVideoDataOutput, inout AVCaptureVideoPreviewLayer?) -> Void)
        async -> (exists: Bool, seconds: Double, video: Double, error: String?, samples: [Double]) {
        var finishError: String?
        var finished = false
        recorder.onFinished = { error in
            DispatchQueue.main.async { finished = true; finishError = error?.localizedDescription }
        }
        recorder.prepareForTake()
        recorder.startRecording(to: url)
        var layer: AVCaptureVideoPreviewLayer?
        var samples: [Double] = []
        for step in 1...12 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if step == 3 { first(recorder, output, &layer) }
            if step == 6 { second(recorder, output, &layer) }
            let written: Double? = await withCheckedContinuation { done in recorder.written { done.resume(returning: $0) } }
            samples.append(written ?? -1)
        }
        let early = finished ? (finishError ?? "ended early with no error") : nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = Once()
            recorder.onFinished = { _ in if once.first() { done.resume() } }
            recorder.stopRecording()
        }
        let info = await probe(url)
        return (info.exists, info.seconds, info.video, early, samples)
    }

    private static func probe(_ url: URL) async -> (exists: Bool, seconds: Double, video: Double, audio: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (false, 0, 0, false) }
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        let audio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        var video = 0.0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let range = try? await track.load(.timeRange) {
            video = range.duration.seconds
        }
        return (true, seconds, video, audio)
    }

    private static func write(_ object: [String: String], to dir: URL) {
        try? JSONSerialization.data(withJSONObject: object).write(to: dir.appendingPathComponent("camera-test.json"))
    }
}

/// `--camera-cpu-test <dir>`: how much CPU the camera costs at idle with extra previews and
/// frame outputs attached, written to <dir>/camera-cpu.json.
enum CameraCPUTest {
    private final class Sink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {}

    @MainActor
    static func run(dir: URL) {
        NSApp.windows.forEach { $0.orderOut(nil) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            guard let cam = AVCaptureDevice.default(for: .video), let mic = AVCaptureDevice.default(for: .audio) else { exit(1) }
            let recorder = CameraRecorder()
            recorder.use(camera: cam, mic: mic)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            var results: [String: Double] = [:]
            func measure(_ label: String) async {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let c0 = clock(), w0 = CACurrentMediaTime()
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                results[label] = Double(clock() - c0) / Double(CLOCKS_PER_SEC) / (CACurrentMediaTime() - w0) * 100
            }
            var flags: [String: Any] = [
                "reactionEffectsEnabled": AVCaptureDevice.reactionEffectsEnabled,
                "reactionEffectGesturesEnabled": AVCaptureDevice.reactionEffectGesturesEnabled,
                "centerStageEnabled": AVCaptureDevice.isCenterStageEnabled,
                "centerStageControlMode": AVCaptureDevice.centerStageControlMode.rawValue,
                "portraitEffectEnabled": AVCaptureDevice.isPortraitEffectEnabled,
                "studioLightEnabled": AVCaptureDevice.isStudioLightEnabled,
                "camera": cam.localizedName,
                "centerStageActive": cam.isCenterStageActive,
                "portraitActive": cam.isPortraitEffectActive,
                "studioLightActive": cam.isStudioLightActive,
                "formatSupportsCenterStage": cam.activeFormat.isCenterStageSupported,
            ]
            await measure("1 session only")
            if cam.activeFormat.isCenterStageSupported {
                AVCaptureDevice.centerStageControlMode = .cooperative
                AVCaptureDevice.isCenterStageEnabled = false
                await measure("1b session, Center Stage off")
                flags["centerStageActiveAfterOff"] = cam.isCenterStageActive
            }
            var layers: [AVCaptureVideoPreviewLayer] = [AVCaptureVideoPreviewLayer(session: recorder.session)]
            await measure("2 plus one preview")
            layers += [AVCaptureVideoPreviewLayer(session: recorder.session), AVCaptureVideoPreviewLayer(session: recorder.session)]
            await measure("3 plus three previews")
            let sink = Sink()
            let output = AVCaptureVideoDataOutput()
            output.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "cpu.sink"))
            recorder.attach(output, framesOn: false)
            await measure("4 plus a frame output, off")
            recorder.setFrames(output, on: true)
            await measure("5 plus a frame output, on")
            layers.removeAll()
            await measure("6 frame output on, no previews")

            // As the app sits idle: the panel's picture on screen, the face box and bubble hidden.
            @MainActor func window(_ layer: CALayer) -> NSPanel {
                let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
                view.wantsLayer = true
                layer.frame = view.bounds
                view.layer?.addSublayer(layer)
                let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.contentView = view
                return panel
            }
            recorder.setFrames(output, on: false)
            let old = (0..<3).map { _ in AVCaptureVideoPreviewLayer(session: recorder.session) }
            let oldWindows = old.map(window)
            oldWindows[0].orderFrontRegardless()
            await measure("7 old: three preview layers, one on screen")
            oldWindows.forEach { $0.orderOut(nil) }
            old.forEach { $0.session = nil }
            let feed = CameraFeed()
            recorder.attach(feed.output)
            let new = (0..<3).map { _ in AVSampleBufferDisplayLayer() }
            new.forEach(feed.show)
            let newWindows = new.map(window)
            newWindows[0].orderFrontRegardless()
            await measure("8 new: feed into three layers, one on screen")
            newWindows.forEach { $0.orderOut(nil) }
            flags["cpu"] = results
            try? JSONSerialization.data(withJSONObject: flags, options: [.prettyPrinted, .sortedKeys])
                .write(to: dir.appendingPathComponent("camera-cpu.json"))
            exit(0)
        }
    }
}

/// `--test-framing <movie> <out.json>`: runs the face framing over a recorded camera file at
/// 5 looks a second, next to the framing used before 4 Oct, and reports how much each moved and
/// how often the face stayed inside the frame.
enum FramingTest {
    @MainActor
    static func run(movie: URL, out: URL) {
        NSApp.windows.forEach { $0.orderOut(nil) }
        Task.detached {
            let asset = AVURLAsset(url: movie)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let reader = try? AVAssetReader(asset: asset) else { exit(1) }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            reader.add(output)
            reader.startReading()
            let tracker = FaceTracker()
            var old: CGRect?
            var oldMisses = 0
            var current: CGRect?
            var stats = (newMoves: 0, oldMoves: 0, newTravel: 0.0, oldTravel: 0.0, looks: 0, faces: 0, newHolds: 0, oldHolds: 0)
            var lastTime = -1.0
            while let sample = output.copyNextSampleBuffer() {
                let t = sample.presentationTimeStamp.seconds
                guard t - lastTime >= 0.2, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                lastTime = t
                stats.looks += 1
                let w = CGFloat(CVPixelBufferGetWidth(pixels)), h = CGFloat(CVPixelBufferGetHeight(pixels))
                let request = VNDetectFaceRectanglesRequest()
                try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
                let face = (request.results ?? []).max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }?.boundingBox

                // New framing.
                if let next = tracker.frame(pixels) {
                    if let c = current { let d = hypot(next.midX - c.midX, next.midY - c.midY); if d > 0.002 { stats.newMoves += 1 }; stats.newTravel += d }
                    current = next
                }
                // The framing before 4 Oct: follow every look, no dead zone.
                var target: CGRect?
                if let box = face {
                    oldMisses = 0
                    let side = min(h, w, max(box.height * h * 2.8, h * 0.25))
                    let cx = min(max(box.midX * w, side / 2), w - side / 2)
                    let cy = min(max(box.midY * h - box.height * h * 0.15, side / 2), h - side / 2)
                    target = CGRect(x: (cx - side / 2) / w, y: (cy - side / 2) / h, width: side / w, height: side / h)
                } else {
                    oldMisses += 1
                    if oldMisses > 10 || old == nil {
                        let side = min(w, h)
                        target = CGRect(x: (w - side) / 2 / w, y: 0, width: side / w, height: side / h)
                    }
                }
                if let target {
                    let next = old.map { o in
                        CGRect(x: o.minX + (target.minX - o.minX) * 0.35, y: o.minY + (target.minY - o.minY) * 0.35,
                               width: o.width + (target.width - o.width) * 0.35, height: o.height + (target.height - o.height) * 0.35)
                    } ?? target
                    if let o = old { let d = hypot(next.midX - o.midX, next.midY - o.midY); if d > 0.002 { stats.oldMoves += 1 }; stats.oldTravel += d }
                    old = next
                }
                if let face {
                    stats.faces += 1
                    if let c = current, c.contains(face) { stats.newHolds += 1 }
                    if let o = old, o.contains(face) { stats.oldHolds += 1 }
                }
            }
            let minutes = max(lastTime, 1) / 60
            let result: [String: Any] = [
                "minutes": minutes, "looks": stats.looks, "looksWithFace": stats.faces,
                "new": ["visibleMovesPerMinute": Double(stats.newMoves) / minutes, "travelPerMinute": stats.newTravel / minutes,
                        "faceInsideFrame": Double(stats.newHolds) / Double(max(stats.faces, 1))],
                "old": ["visibleMovesPerMinute": Double(stats.oldMoves) / minutes, "travelPerMinute": stats.oldTravel / minutes,
                        "faceInsideFrame": Double(stats.oldHolds) / Double(max(stats.faces, 1))],
            ]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out)
            exit(0)
        }
    }
}

/// `--screen-camera-test <dir>`: records camera.mov while ScreenCaptureKit records the screen,
/// in a few variations, and writes how much camera picture survived to <dir>/screen-camera.json.
/// Built to find out why the camera picture stopped 0.13 s into every take with a screen on 4 Oct.
enum ScreenCameraTest {
    private final class Sink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {}

    struct Outcome: Encodable {
        var name: String
        var note: String?
        var cameraPicture: Double
        var cameraTotal: Double
        var screenPicture: Double
    }

    @MainActor
    static func run(dir: URL) {
        NSApp.windows.forEach { $0.orderOut(nil) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            func fail(_ why: String) -> Never {
                try? Data(why.utf8).write(to: dir.appendingPathComponent("screen-camera.json"))
                exit(1)
            }
            guard let cam = AVCaptureDevice.default(for: .video), let mic = AVCaptureDevice.default(for: .audio) else { fail("no camera or mic") }
            let content: SCShareableContent
            do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) } catch { fail("screen: \(error)") }
            guard let display = content.displays.first else { fail("no display") }
            let plain = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let withoutMe = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let full = CGSize(width: display.width * 2, height: display.height * 2)
            struct Case {
                var name: String
                var screenFirst = true
                var mic = true
                var size: CGSize
                var filter: SCContentFilter
                var update = false
                var window = false
                /// Two frame outputs attached with frames off, switched on by prepareForTake, as in the app.
                var outputs = false
                /// False: wait as long as the screen takes to start, but start no screen.
                var screen = true
                /// The preview window is hidden 0.7 s into the take, as the panel is when a take starts.
                var hide = false
                /// The preview gets copies of frames (CameraFeed) instead of joining the session.
                var feed = false
            }
            let half = CGSize(width: display.width, height: display.height)
            let cases: [Case] = [
                Case(name: "screen first, with mic", size: full, filter: plain),
                Case(name: "screen first, no mic", mic: false, size: full, filter: plain),
                Case(name: "camera first, screen 2 s later, with mic", screenFirst: false, size: full, filter: plain),
                Case(name: "screen first, with mic, half size", size: half, filter: plain),
                Case(name: "filter update after camera starts", size: full, filter: plain, update: true),
                Case(name: "filter update, app left out", size: full, filter: withoutMe, update: true),
                Case(name: "filter update, app left out, preview window", size: full, filter: withoutMe, update: true, window: true),
                Case(name: "no update, app left out, preview window", size: full, filter: withoutMe, window: true),
                Case(name: "outputs switched on, then screen, then camera", size: full, filter: withoutMe, outputs: true),
                Case(name: "outputs switched on, 1 s wait, then camera, no screen", size: full, filter: withoutMe, outputs: true, screen: false),
                Case(name: "old preview window hidden mid-take", size: full, filter: withoutMe, window: true, hide: true),
                Case(name: "fed preview window hidden mid-take", size: full, filter: withoutMe, window: true, hide: true, feed: true),
            ]
            let only = ProcessInfo.processInfo.environment["AVA_CASES"]?.split(separator: ",")
            var results: [Outcome] = []
            let sink = Sink()
            for c in cases where only.map({ $0.contains { c.name.contains($0) } }) ?? true {
                let recorder = CameraRecorder()
                let screen = ScreenRecorder()
                var taps: [AVCaptureVideoDataOutput] = []
                if c.outputs {
                    for _ in 0..<2 {
                        let tap = AVCaptureVideoDataOutput()
                        tap.alwaysDiscardsLateVideoFrames = true
                        tap.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                        tap.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "test.tap"))
                        recorder.attach(tap, framesOn: false)
                        taps.append(tap)
                    }
                }
                recorder.use(camera: cam, mic: mic)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let slug = c.name.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "-")
                let camURL = dir.appendingPathComponent(slug + "-camera.mov")
                let scrURL = dir.appendingPathComponent(slug + "-screen.mov")
                [camURL, scrURL].forEach { try? FileManager.default.removeItem(at: $0) }
                // A window showing the camera, like the face box: the old preview layer joined to the
                // session, or the new one fed with copies of frames.
                var window: NSPanel?
                var note: String?
                let feed = CameraFeed()
                if c.feed { recorder.attach(feed.output) }
                if c.window {
                    let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
                    view.wantsLayer = true
                    if c.feed {
                        let layer = AVSampleBufferDisplayLayer()
                        layer.frame = view.bounds
                        view.layer?.addSublayer(layer)
                        feed.show(on: layer)
                    } else {
                        let layer = AVCaptureVideoPreviewLayer(session: recorder.session)
                        layer.frame = view.bounds
                        view.layer?.addSublayer(layer)
                        note = "old preview mirrored: \(layer.connection?.isVideoMirrored ?? false), camera position \(cam.position.rawValue)"
                    }
                    let panel = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 240, height: 240),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.contentView = view
                    panel.orderFrontRegardless()
                    window = panel
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                recorder.prepareForTake()
                if !c.screen {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    recorder.startRecording(to: camURL)
                } else if c.screenFirst {
                    try? await screen.start(filter: c.filter, display: display, pixelSize: c.size, micID: c.mic ? mic.uniqueID : nil, to: scrURL)
                    recorder.startRecording(to: camURL)
                } else {
                    recorder.startRecording(to: camURL)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    try? await screen.start(filter: c.filter, display: display, pixelSize: c.size, micID: c.mic ? mic.uniqueID : nil, to: scrURL)
                }
                if c.update {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    try? await screen.update(c.filter)
                }
                if c.hide {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    window?.orderOut(nil)
                }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    let once = Once()
                    recorder.onFinished = { _ in if once.first() { done.resume() } }
                    recorder.stopRecording()
                }
                await screen.stop()
                window?.orderOut(nil)
                recorder.release()
                _ = taps
                results.append(Outcome(name: c.name, note: note, cameraPicture: await picture(camURL),
                                       cameraTotal: (try? await AVURLAsset(url: camURL).load(.duration))?.seconds ?? 0,
                                       screenPicture: await picture(scrURL)))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try? encoder.encode(results).write(to: dir.appendingPathComponent("screen-camera.json"))
            exit(0)
        }
    }

    private static func picture(_ url: URL) async -> Double {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange) else { return 0 }
        return range.duration.seconds
    }
}
