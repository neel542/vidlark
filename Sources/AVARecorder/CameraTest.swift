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
    /// The face framing as it was until 5 Oct, kept only to compare against: 5 looks a second,
    /// a new Vision request each time, a still zone of 0.12 and a 30% step towards it per look.
    final class Before {
        private var smoothed: CGRect?
        private var goal: CGRect?
        private var misses = 0

        private func square(side: CGFloat, cx: CGFloat, cy: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            let x = min(max(cx, side / 2), width - side / 2)
            let y = min(max(cy, side / 2), height - side / 2)
            return CGRect(x: (x - side / 2) / width, y: (y - side / 2) / height, width: side / width, height: side / height)
        }

        func frame(_ pixels: CVPixelBuffer) -> CGRect? {
            let width = CGFloat(CVPixelBufferGetWidth(pixels)), height = CGFloat(CVPixelBufferGetHeight(pixels))
            let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
            let faces = VNDetectFaceRectanglesRequest()
            try? handler.perform([faces])
            let face = (faces.results ?? []).max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
            var target: CGRect?
            if let box = face?.boundingBox {
                misses = 0
                let side = min(height, width, max(box.height * height * 2.8, height * 0.25))
                target = square(side: side, cx: box.midX * width, cy: box.midY * height - box.height * height * 0.15, width, height)
            } else {
                misses += 1
                if misses > 10 {
                    let bodies = VNDetectHumanRectanglesRequest()
                    bodies.upperBodyOnly = true
                    try? handler.perform([bodies])
                    if let body = (bodies.results ?? []).max(by: { $0.boundingBox.height < $1.boundingBox.height })?.boundingBox {
                        let side = min(height, width, max(body.width * width * 1.25, height * 0.35))
                        target = square(side: side, cx: body.midX * width, cy: body.maxY * height - side * 0.45, width, height)
                    } else if misses > 25 || smoothed == nil {
                        let side = min(width, height)
                        target = CGRect(x: (width - side) / 2 / width, y: 0, width: side / width, height: side / height)
                    }
                }
            }
            if let target {
                if let goal, let current = smoothed {
                    let drift = hypot(target.midX - goal.midX, (target.midY - goal.midY) * height / width) / current.width
                    if drift > 0.12 || abs(target.width / goal.width - 1) > 0.18 { self.goal = target }
                } else {
                    goal = target
                }
            }
            guard let goal else { return nil }
            guard let old = smoothed else { smoothed = goal; return goal }
            let k: CGFloat = 0.3
            let next = CGRect(x: old.minX + (goal.minX - old.minX) * k, y: old.minY + (goal.minY - old.minY) * k,
                              width: old.width + (goal.width - old.width) * k, height: old.height + (goal.height - old.height) * k)
            if abs(next.minX - old.minX) < 0.0005, abs(next.minY - old.minY) < 0.0005, abs(next.width - old.width) < 0.0005 { return nil }
            smoothed = next
            return next
        }
    }

    /// What the box shows: a glide from where the picture is to each new framing.
    struct Screen {
        var duration: Double
        var from = CGRect.zero, to = CGRect.zero, start = -100.0

        mutating func set(_ crop: CGRect, at t: Double) {
            from = start < -50 ? crop : at(t)
            to = crop
            start = t
        }

        func at(_ t: Double) -> CGRect {
            let p = min(max((t - start) / duration, 0), 1)
            let e = 1 - pow(1 - p, 3)
            return CGRect(x: from.minX + (to.minX - from.minX) * e, y: from.minY + (to.minY - from.minY) * e,
                          width: from.width + (to.width - from.width) * e, height: from.height + (to.height - from.height) * e)
        }
    }

    /// `--test-framing <camera.mov> <out.json>`: runs the old and new framing over a real take and
    /// scores what the box would show, 30 times a second, against where the face really is.
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

            func cpu() -> Double {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            }
            struct Score {
                var looks = 0, cpu = 0.0, moves = 0, inside = 0, offCentre = 0.0, offFrames = 0, scored = 0
                var last: CGRect?
            }
            let before = Before(), after = FaceTracker()
            var b = Score(), a = Score()
            var bScreen = Screen(duration: 0.4), aScreen = Screen(duration: 0.5)
            var bLast = -1.0, aLast = -1.0, truthLast = -1.0, frameLast = -1.0, end = 0.0
            var truth: CGRect?
            let truthRequest = VNDetectFaceRectanglesRequest()

            func score(_ s: inout Score, _ shown: CGRect, face: CGRect, aspect: CGFloat) {
                s.scored += 1
                if shown.contains(face) { s.inside += 1 }
                let off = hypot(face.midX - shown.midX, (face.midY - shown.midY) / aspect) / shown.width
                s.offCentre += off
                if off > 0.25 { s.offFrames += 1 }
            }

            while let sample = output.copyNextSampleBuffer() {
                let t = sample.presentationTimeStamp.seconds
                end = t
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                let aspect = CGFloat(CVPixelBufferGetWidth(pixels)) / CGFloat(CVPixelBufferGetHeight(pixels))
                // Where the face really is, 10 times a second. Not counted as either tracker's cost.
                if t - truthLast >= 0.1 {
                    truthLast = t
                    try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([truthRequest])
                    truth = (truthRequest.results ?? []).max { $0.boundingBox.width < $1.boundingBox.width }?.boundingBox
                }
                if t - bLast >= 0.2 {
                    bLast = t
                    let c = cpu()
                    let next = before.frame(pixels)
                    b.cpu += cpu() - c
                    b.looks += 1
                    if let next { if let l = b.last, hypot(next.midX - l.midX, next.midY - l.midY) > 0.002 { b.moves += 1 }; b.last = next; bScreen.set(next, at: t) }
                }
                if t - aLast >= after.interval(at: t) - 0.01 {
                    aLast = t
                    let c = cpu()
                    let next = after.frame(pixels, at: t)
                    a.cpu += cpu() - c
                    a.looks += 1
                    if let next { if let l = a.last, hypot(next.midX - l.midX, next.midY - l.midY) > 0.002 { a.moves += 1 }; a.last = next; aScreen.set(next, at: t) }
                }
                if t - frameLast >= 1.0 / 30, let face = truth {
                    frameLast = t
                    if b.last != nil { score(&b, bScreen.at(t), face: face, aspect: aspect) }
                    if a.last != nil { score(&a, aScreen.at(t), face: face, aspect: aspect) }
                }
            }
            let minutes = max(end, 1) / 60
            func report(_ s: Score) -> [String: Any] {
                ["looksPerSecond": Double(s.looks) / (minutes * 60),
                 "cpuMillisecondsPerSecond": s.cpu * 1000 / (minutes * 60),
                 "framingChangesPerMinute": Double(s.moves) / minutes,
                 "faceWhollyInBox": Double(s.inside) / Double(max(s.scored, 1)),
                 "averageOffCentre": s.offCentre / Double(max(s.scored, 1)),
                 "secondsBadlyOffCentrePerMinute": Double(s.offFrames) / 30 / minutes]
            }
            let result: [String: Any] = ["seconds": end, "before": report(b), "after": report(a)]
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
