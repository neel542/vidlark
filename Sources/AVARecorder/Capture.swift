import AVFoundation
import CoreAudio
import QuartzCore
import ScreenCaptureKit

// MARK: - Devices

enum Devices {
    static func cameras() -> [AVCaptureDevice] {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external, .builtInWideAngleCamera],
            mediaType: .video, position: .unspecified).devices
        return unique(found).sorted { cameraRank($0) > cameraRank($1) }
    }

    static func mics() -> [AVCaptureDevice] {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
        return unique(found).filter { micRank($0) > 0 }.sorted { micRank($0) > micRank($1) }
    }

    /// The iPhone first, then any plugged-in camera, then the Mac's own.
    static func cameraRank(_ d: AVCaptureDevice) -> Int {
        if d.deviceType == .continuityCamera { return 3 }
        if d.deviceType == .external { return 2 }
        return 1
    }

    /// A USB receiver first, then Bluetooth, then the iPhone, then the Mac's own mic.
    /// Virtual devices from meeting apps are hidden.
    static func micRank(_ d: AVCaptureDevice) -> Int {
        let name = d.localizedName.lowercased()
        let virtual = ["zoom", "teams", "blackhole", "loopback", "soundflower", "aggregate", "virtual", "camo"]
        if virtual.contains(where: name.contains) { return 0 }
        switch UInt32(bitPattern: d.transportType) {
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return 0
        case kAudioDeviceTransportTypeUSB: return 5
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return 3
        case kAudioDeviceTransportTypeBuiltIn: return 1
        default: return 2
        }
    }

    private static func unique(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        var seen = Set<String>()
        return devices.filter { seen.insert($0.uniqueID).inserted }
    }
}

// MARK: - Camera and mic

/// How sharp the camera records. Higher is sharper and makes bigger files.
enum CameraQuality: String, CaseIterable, Identifiable {
    case best, uhd, fullHD, hd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: "Best it offers"
        case .uhd: "4K"
        case .fullHD: "1080p"
        case .hd: "720p"
        }
    }

    /// The picture height asked for; nil takes the biggest.
    var height: Int32? {
        switch self {
        case .best: nil
        case .uhd: 2160
        case .fullHD: 1080
        case .hd: 720
        }
    }
}

/// What the camera is recording right now.
struct CameraFormat: Equatable {
    var width: Int
    var height: Int
    var fps: Int

    /// "1080p", "4K", "720p", or the size for anything else.
    var name: String {
        switch height {
        case 2160: "4K"
        case 1080, 1440: "\(height)p"
        case 720: "720p"
        default: "\(width) × \(height)"
        }
    }

    var text: String { "\(name) at \(fps) frames a second" }

    /// About how big 15 minutes of camera.mov gets, measured on 4 Oct at 0.08 bits a pixel in HEVC.
    var gigabytesPer15Minutes: Double { Double(width * height * fps) * 0.08 * 900 / 8 / 1_000_000_000 }
}

/// iPhone video plus the mic, into camera.mov. Writes 2 second fragments so a crash keeps the take.
final class CameraRecorder: NSObject {
    let session = AVCaptureSession()
    private let movie = AVCaptureMovieFileOutput()
    private let levelTap = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "ava.camera")
    private let tapQueue = DispatchQueue(label: "ava.camera.level")
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var lastLevel: CFTimeInterval = 0
    private var onAudio: ((CMSampleBuffer) -> Void)?
    /// Extra frame outputs (face tracker, live view) and whether each wants frames. Camera queue only.
    private var frameOutputs: [(output: AVCaptureOutput, wanted: Bool)] = []
    /// True from the start of a take until its file closes. Camera queue only.
    private var taking = false
    /// When the session will have settled after the last connection was switched on. Camera queue only.
    private var settled: CFTimeInterval = 0

    var onLevel: ((Float, Float) -> Void)?
    /// The format the camera ended up recording in, after each `use`. Called on the camera queue.
    var onFormat: ((CameraFormat?) -> Void)?
    var onStarted: ((CFTimeInterval) -> Void)?
    var onFinished: ((Error?) -> Void)?

    override init() {
        super.init()
        movie.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        levelTap.setSampleBufferDelegate(self, queue: tapQueue)
    }

    func use(camera: AVCaptureDevice?, mic: AVCaptureDevice?, quality: CameraQuality = .best, smooth: Bool = false) {
        queue.async { [self] in
            session.beginConfiguration()
            if let v = videoInput { session.removeInput(v); videoInput = nil }
            if let a = audioInput { session.removeInput(a); audioInput = nil }
            if let camera, let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
                session.addInput(input); videoInput = input
            }
            if let mic, let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                session.addInput(input); audioInput = input
            }
            if !session.outputs.contains(movie), session.canAddOutput(movie) { session.addOutput(movie) }
            if !session.outputs.contains(levelTap), session.canAddOutput(levelTap) { session.addOutput(levelTap) }
            session.commitConfiguration()

            onFormat?(camera.flatMap { Self.useFormat($0, quality: quality, fps: smooth ? 60 : 30) })
            if let connection = movie.connection(with: .video) {
                movie.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
            if !taking { frameOutputs.forEach { $0.output.connection(with: .video)?.isEnabled = $0.wanted } }
            if !session.isRunning { session.startRunning() }
        }
    }

    /// The picture asked for: the quality's height (or the biggest), widescreen first, at `fps`
    /// when the camera can, otherwise at 30. Returns what it set.
    private static func useFormat(_ device: AVCaptureDevice, quality: CameraQuality, fps wanted: Int) -> CameraFormat? {
        func size(_ f: AVCaptureDevice.Format) -> CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(f.formatDescription) }
        func runs(_ f: AVCaptureDevice.Format, _ rate: Int) -> Bool {
            f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(rate) - 0.1 && $0.minFrameRate <= Double(rate) + 0.1 }
        }
        func widescreen(_ f: AVCaptureDevice.Format) -> Bool {
            let d = size(f)
            return abs(Double(d.width) / Double(max(d.height, 1)) - 16.0 / 9.0) < 0.02
        }
        func pick(_ rate: Int) -> AVCaptureDevice.Format? {
            let able = device.formats.filter { runs($0, rate) }
            // Widescreen is what YouTube shows; a square or 4:3 picture only when nothing else fits.
            let pool = able.contains(where: widescreen) ? able.filter(widescreen) : able
            let fitting = quality.height.map { h in pool.filter { size($0).height <= h } } ?? pool
            let choices = fitting.isEmpty ? pool : fitting
            return choices.max { Int(size($0).width) * Int(size($0).height) < Int(size($1).width) * Int(size($1).height) }
        }
        var rate = wanted
        var format = pick(rate)
        if format == nil, rate != 30 { rate = 30; format = pick(30) }
        guard let format else { return nil }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let frame = CMTime(value: 1, timescale: CMTimeScale(rate))
            device.activeVideoMinFrameDuration = frame
            device.activeVideoMaxFrameDuration = frame
            device.unlockForConfiguration()
        } catch {
            return nil
        }
        let d = size(format)
        return CameraFormat(width: Int(d.width), height: Int(d.height), fps: rate)
    }

    func startRecording(to url: URL) {
        queue.async { [self] in
            frameOutputsOnForTake()
            // Give a just-changed session half a second to settle before the file opens.
            let wait = max(0, settled - CACurrentMediaTime())
            queue.asyncAfter(deadline: .now() + wait) { [self] in movie.startRecording(to: url, recordingDelegate: self) }
        }
    }

    /// Switches every extra output on ahead of a take, so nothing about the session changes once
    /// the file is open. Turning one on or off mid-take is what lost a whole camera file on 4 Oct.
    func prepareForTake() {
        queue.async { [self] in frameOutputsOnForTake() }
    }

    /// Asks for frames to an extra output, or stops them. During a take the change waits until
    /// the file has closed; the output just drops the frames it does not want until then.
    func setFrames(_ output: AVCaptureOutput, on: Bool) {
        queue.async { [self] in
            guard let i = frameOutputs.firstIndex(where: { $0.output === output }) else { return }
            frameOutputs[i].wanted = on
            if !taking { output.connection(with: .video)?.isEnabled = on }
        }
    }

    /// How many seconds the open movie file holds, or nil when no file is open.
    func written(_ reply: @escaping (Double?) -> Void) {
        queue.async { [self] in reply(movie.isRecording ? movie.recordedDuration.seconds : nil) }
    }

    /// Camera queue only. Switching a connection on means the file waits until `settled`.
    private func frameOutputsOnForTake() {
        taking = true
        for item in frameOutputs {
            if let connection = item.output.connection(with: .video), !connection.isEnabled {
                connection.isEnabled = true
                settled = CACurrentMediaTime() + 0.5
            }
        }
    }

    /// Camera queue only. The take is over, so outputs go back to what they asked for.
    private func takeEnded() {
        taking = false
        frameOutputs.forEach { $0.output.connection(with: .video)?.isEnabled = $0.wanted }
    }

    /// Lets go of the camera and mic, for an extra camera that is no longer wanted.
    func release() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
            videoInput = nil
            audioInput = nil
        }
    }

    func stopRecording() {
        queue.async { [self] in
            if movie.isRecording { movie.stopRecording() } else { takeEnded(); onFinished?(nil) }
        }
    }

    /// Adds another output to the camera session, such as the face tracker's frame tap. Its frames
    /// start off or on as asked; change that later with `setFrames`, never on the connection itself.
    func attach(_ output: AVCaptureOutput, framesOn: Bool = true) {
        queue.async { [self] in
            guard !session.outputs.contains(output), session.canAddOutput(output) else { return }
            session.beginConfiguration()
            session.addOutput(output)
            session.commitConfiguration()
            frameOutputs.append((output, framesOn))
            if !taking { output.connection(with: .video)?.isEnabled = framesOn }
        }
    }

    /// Hands every mic buffer to the voice follower as well. Set on the tap queue, where it is read.
    func forwardAudio(_ handler: ((CMSampleBuffer) -> Void)?) {
        tapQueue.async { [self] in onAudio = handler }
    }

    var dimensions: CGSize? {
        guard let device = videoInput?.device else { return nil }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return CGSize(width: Int(d.width), height: Int(d.height))
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        onStarted?(CACurrentMediaTime())
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        var result = error
        if let e = error as NSError?, (e.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true {
            result = nil
        }
        queue.async { [self] in
            takeEnded()
            onFinished?(result)
        }
    }
}

extension CameraRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onAudio?(sampleBuffer)
        let now = CACurrentMediaTime()
        guard now - lastLevel > 0.066 else { return }
        lastLevel = now
        let channels = connection.audioChannels
        guard !channels.isEmpty else { return }
        let average = channels.map(\.averagePowerLevel).max() ?? -160
        let peak = channels.map(\.peakHoldLevel).max() ?? -160
        onLevel?(average, peak)
    }
}

// MARK: - Previews

/// The camera picture for every preview on screen (panel, face box, bubble), from one frame output.
/// Previews used to be AVCaptureVideoPreviewLayers, which belong to the camera session: a window
/// hiding or showing one at the start of a take changed the session and camera.mov stopped within
/// a second. On 4 Oct every test take lost its picture that way, and none did with no preview layers.
/// These layers only get copies of frames, so nothing on screen can touch the session.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "ava.preview")
    private let lock = NSLock()
    private let layers = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()
    /// The layers that can be seen right now. Only these get frames: a hidden layer that kept
    /// taking them would hold on to the camera's buffers, and a camera short of buffers stalls.
    private var seen = Set<ObjectIdentifier>()
    private var handed = 0
    private var frameSize = CGSize(width: 16, height: 9)

    /// Width over height of the camera picture, from the latest frame.
    var aspect: CGFloat { lock.withLock { frameSize.width / max(frameSize.height, 1) } }

    /// How many frames went to a preview, and each preview's state, for the self test.
    var report: (frames: Int, states: [String]) {
        lock.withLock {
            (handed, layers.allObjects.map { ["unknown", "rendering", "failed"][min(max($0.sampleBufferRenderer.status.rawValue, 0), 2)] })
        }
    }

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func show(on layer: AVSampleBufferDisplayLayer) {
        // Camera frames are stamped with the host clock, so a layer run by that clock shows each
        // one as it arrives. (Marking frames "display immediately" instead changes data the camera
        // shares between threads, and crashed the app on 4 Oct.)
        let host = CMClockGetHostTimeClock()
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: host, timebaseOut: &timebase) == noErr,
           let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(host))
            CMTimebaseSetRate(timebase, rate: 1)
            layer.controlTimebase = timebase
        }
        lock.withLock { layers.add(layer) }
    }

    /// Whether this layer can be seen. Hidden, it lets go of every frame it holds.
    func set(_ layer: AVSampleBufferDisplayLayer, seen visible: Bool) {
        lock.withLock { if visible { seen.insert(ObjectIdentifier(layer)) } else { seen.remove(ObjectIdentifier(layer)) } }
        if !visible { layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            lock.withLock { frameSize = size }
        }
        for layer in lock.withLock({ layers.allObjects.filter { seen.contains(ObjectIdentifier($0)) } }) {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            // A layer in a hidden window stops taking frames; it is skipped until it shows again.
            if renderer.isReadyForMoreMediaData {
                renderer.enqueue(sampleBuffer)
                lock.withLock { handed += 1 }
            }
        }
    }
}

// MARK: - Screen

/// The content screen plus the same mic, into screen.mov. The shared mic is what lets the
/// finisher line the two files up exactly. The app's own windows and Notification Center are
/// cut out of the picture. With `systemAudio`, what the Mac plays goes in as a second sound track
/// (the mic stays the first, which the finisher reads).
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var systemIn: AVAssetWriterInput?
    private var wantsSystemAudio = false
    private let queue = DispatchQueue(label: "ava.screen")
    private var started = false
    private var wantsAudio = false
    private var audioFormat: CMFormatDescription?
    private var streamStart: CFTimeInterval = 0
    private var url: URL?
    private var size = (width: 0, height: 0)
    private var lastFrame: CMSampleBuffer?

    var onError: ((Error) -> Void)?
    /// Every complete screen frame, for the live view. Called on the stream queue.
    var onFrame: ((CVPixelBuffer) -> Void)?

    func start(filter: SCContentFilter, pixelSize: CGSize, micID: String?, systemAudio: Bool = false, to url: URL) async throws {
        self.url = url
        started = false
        audioFormat = nil
        size = (Int(pixelSize.width) & ~1, Int(pixelSize.height) & ~1)

        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 8
        config.capturesAudio = systemAudio
        if systemAudio {
            // The app's own sounds (the countdown beeps) stay out.
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        wantsSystemAudio = systemAudio
        wantsAudio = micID != nil
        if let micID {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = micID
        }

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if wantsAudio { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        if systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        stream = s
        streamStart = CACurrentMediaTime()
        try await s.startCapture()
    }

    func stop() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard let w = writer, w.status == .writing else {
                    writer = nil; done.resume(); return
                }
                // A still screen sends no new frames. Repeat the last one at the stop time so the
                // video track runs as long as the audio.
                let end = CMClockGetTime(CMClockGetHostTimeClock())
                if let last = lastFrame, let v = videoIn, v.isReadyForMoreMediaData,
                   CMTimeCompare(end, last.presentationTimeStamp) > 0 {
                    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: end, decodeTimeStamp: .invalid)
                    var copy: CMSampleBuffer?
                    if CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1,
                                                             sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                       let copy {
                        v.append(copy)
                    }
                }
                lastFrame = nil
                videoIn?.markAsFinished()
                audioIn?.markAsFinished()
                systemIn?.markAsFinished()
                w.finishWriting { [self] in
                    writer = nil; videoIn = nil; audioIn = nil; systemIn = nil
                    done.resume()
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                                as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            if !started {
                // Wait briefly for the first mic buffer so the audio track matches its format.
                if wantsAudio && audioFormat == nil && CACurrentMediaTime() - streamStart < 1.5 { return }
                guard openWriter(at: sampleBuffer.presentationTimeStamp) else { return }
            }
            if let v = videoIn, v.isReadyForMoreMediaData, v.append(sampleBuffer) { lastFrame = sampleBuffer }
            if let onFrame, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) { onFrame(pixels) }
        case .microphone:
            if audioFormat == nil { audioFormat = sampleBuffer.formatDescription }
            if started, let a = audioIn, a.isReadyForMoreMediaData { a.append(sampleBuffer) }
        case .audio:
            if started, let s = systemIn, s.isReadyForMoreMediaData { s.append(sampleBuffer) }
        default:
            break
        }
    }

    /// Changes what is recorded mid-take, for example to let the face bubble in.
    func update(_ filter: SCContentFilter) async throws {
        try await stream?.updateContentFilter(filter)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    private func openWriter(at time: CMTime) -> Bool {
        guard let url else { return false }
        do {
            try? FileManager.default.removeItem(at: url)
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

            let bitrate = Int(Double(size.width * size.height) * 30 * 0.08)
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                ],
            ])
            v.expectsMediaDataInRealTime = true
            guard w.canAdd(v) else { return false }
            w.add(v)
            videoIn = v

            if let format = audioFormat,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                let channels = min(max(Int(asbd.mChannelsPerFrame), 1), 2)
                var settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: min(asbd.mSampleRate, 48_000),
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
                ]
                if channels == 2 {
                    var layout = AudioChannelLayout()
                    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
                    settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
                }
                let a = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
                a.expectsMediaDataInRealTime = true
                if w.canAdd(a) { w.add(a); audioIn = a }
            }

            // The Mac's sound, after the mic so the mic stays the first sound track.
            systemIn = nil
            if wantsSystemAudio {
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
                let s = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000,
                    AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
                ])
                s.expectsMediaDataInRealTime = true
                if w.canAdd(s) { w.add(s); systemIn = s }
            }

            guard w.startWriting() else { return false }
            w.startSession(atSourceTime: time)
            writer = w
            started = true
            return true
        } catch {
            onError?(error)
            return false
        }
    }
}

// MARK: - Displays

struct DisplayChoice: Identifiable, Equatable {
    var id: CGDirectDisplayID
    var name: String
    var pixelSize: CGSize
    var builtIn: Bool

    static func all() -> [DisplayChoice] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let scale = screen.backingScaleFactor
            return DisplayChoice(id: id,
                                 name: screen.localizedName,
                                 pixelSize: CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale),
                                 builtIn: CGDisplayIsBuiltin(id) != 0)
        }
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }
}
