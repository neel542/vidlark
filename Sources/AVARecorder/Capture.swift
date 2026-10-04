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

    var onLevel: ((Float, Float) -> Void)?
    var onStarted: ((CFTimeInterval) -> Void)?
    var onFinished: ((Error?) -> Void)?

    override init() {
        super.init()
        movie.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        levelTap.setSampleBufferDelegate(self, queue: tapQueue)
    }

    func use(camera: AVCaptureDevice?, mic: AVCaptureDevice?) {
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

            if let camera { Self.useLargestFormat(camera) }
            if let connection = movie.connection(with: .video) {
                movie.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    /// The biggest picture the camera offers at 30 frames a second or more.
    private static func useLargestFormat(_ device: AVCaptureDevice) {
        func pixels(_ f: AVCaptureDevice.Format) -> Int32 {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width * d.height
        }
        let candidates = device.formats.filter { f in
            f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29.9 && $0.minFrameRate <= 30.1 }
        }
        guard let best = candidates.max(by: { pixels($0) < pixels($1) }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            let thirty = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = thirty
            device.activeVideoMaxFrameDuration = thirty
            device.unlockForConfiguration()
        } catch {}
    }

    func startRecording(to url: URL) {
        queue.async { [self] in movie.startRecording(to: url, recordingDelegate: self) }
    }

    func stopRecording() {
        queue.async { [self] in
            if movie.isRecording { movie.stopRecording() } else { onFinished?(nil) }
        }
    }

    /// Hands every mic buffer to the voice follower as well. Set on the tap queue, where it is read.
    /// Adds another output to the camera session, such as the face tracker's frame tap.
    func attach(_ output: AVCaptureOutput) {
        queue.async { [self] in
            guard !session.outputs.contains(output), session.canAddOutput(output) else { return }
            session.beginConfiguration()
            session.addOutput(output)
            session.commitConfiguration()
        }
    }

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
        onFinished?(result)
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

// MARK: - Screen

/// The content screen plus the same mic, into screen.mov. The shared mic is what lets the
/// finisher line the two files up exactly. The app's own windows and Notification Center are
/// cut out of the picture.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "ava.screen")
    private var started = false
    private var wantsAudio = false
    private var audioFormat: CMFormatDescription?
    private var streamStart: CFTimeInterval = 0
    private var url: URL?
    private var size = (width: 0, height: 0)
    private var lastFrame: CMSampleBuffer?

    var onError: ((Error) -> Void)?

    func start(filter: SCContentFilter, pixelSize: CGSize, micID: String?, to url: URL) async throws {
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
        config.capturesAudio = false
        wantsAudio = micID != nil
        if let micID {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = micID
        }

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if wantsAudio { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
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
                w.finishWriting { [self] in
                    writer = nil; videoIn = nil; audioIn = nil
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
        case .microphone:
            if audioFormat == nil { audioFormat = sampleBuffer.formatDescription }
            if started, let a = audioIn, a.isReadyForMoreMediaData { a.append(sampleBuffer) }
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
