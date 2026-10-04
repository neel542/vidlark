import AVFoundation
import AppKit

/// `--camera-test <dir>`: records short camera files while changing the camera session the ways
/// the app can mid-take, and writes what survived to <dir>/camera-test.json. Built to find out
/// why a whole camera.mov went missing on 4 Oct.
enum CameraTest {
    private final class Sink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {}

    struct Outcome: Encodable {
        var name: String
        var fileExists: Bool
        var seconds: Double
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
            ]
            for (name, first, second) in cases {
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
                                       error: outcome.error, writtenSamples: outcome.samples))
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
        async -> (exists: Bool, seconds: Double, error: String?, samples: [Double]) {
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
        return (info.exists, info.seconds, early, samples)
    }

    private static func probe(_ url: URL) async -> (exists: Bool, seconds: Double, audio: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (false, 0, false) }
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        let audio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        return (true, seconds, audio)
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
            flags["cpu"] = results
            try? JSONSerialization.data(withJSONObject: flags, options: [.prettyPrinted, .sortedKeys])
                .write(to: dir.appendingPathComponent("camera-cpu.json"))
            exit(0)
        }
    }
}
