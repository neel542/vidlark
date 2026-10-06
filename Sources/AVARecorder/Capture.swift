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

/// Light mode films at 1080p and 30 frames a second, so a slower Mac keeps up. Automatic
/// switches it on for a slower Mac (`Machine.modest`) and while Low Power Mode is on.
enum LightMode: String, CaseIterable {
    case automatic, on, off
}

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

    /// "1080p", "4K", "720p", or the size for anything else. A tall picture (a phone's 9:16) is
    /// "1080p tall".
    var name: String {
        if height > width { return CameraFormat(width: height, height: width, fps: fps).name + " tall" }
        return switch height {
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
    private var onLiveAudio: ((CMSampleBuffer) -> Void)?
    /// Extra frame outputs (face tracker, live view) and whether each wants frames. Camera queue only.
    private var frameOutputs: [(output: AVCaptureOutput, wanted: Bool)] = []
    /// True from the start of a take until its file closes. Camera queue only.
    private var taking = false
    /// When the session will have settled after the last connection was switched on. Camera queue only.
    private var settled: CFTimeInterval = 0
    /// True while the camera rests: the session is stopped and the camera light is off. Camera queue only.
    private var resting = false
    /// A phone over Wi-Fi, while it is this recorder's camera. Its pictures come from the phone link
    /// instead of the session, which then holds only the mic. Camera queue only.
    private var phone: PhoneCamera?
    /// camera.mov from the iPhone's pictures and the mic. Phone queue only.
    private var phoneTake: PhoneTake?
    /// The mic's sound format, for the iPhone take's file. Phone queue only.
    private var micFormat: CMFormatDescription?
    private let phoneQueue = DispatchQueue(label: "ava.camera.phone")
    /// The frame outputs that get the iPhone's decoded pictures, and whether the mic goes to the
    /// iPhone take. Under `phoneLock`.
    private var phoneTargets: [PhoneTarget] = []
    private var phoneOn = false
    private let phoneLock = NSLock()
    /// Phones filming other angles take this recorder's mic, so they need no capture session of
    /// their own: one mic session for the take, however many phones. Tap queue only.
    private var micTakers: [CameraRecorder] = []

    var onLevel: ((Float, Float) -> Void)?
    /// The format the camera ended up recording in, after each `use`. Called on the camera queue.
    var onFormat: ((CameraFormat?) -> Void)?
    var onStarted: ((CFTimeInterval) -> Void)?
    /// Pictures from a phone that did not go into the last take's file, by why. Read after it closes.
    private(set) var phoneDropped: [String: Int] = [:]
    /// Each take's file says it started once, whichever of the delegate's two ways comes first.
    fileprivate var startedOnce = Once()
    var onFinished: ((Error?) -> Void)?

    override init() {
        super.init()
        movie.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        levelTap.setSampleBufferDelegate(self, queue: tapQueue)
    }

    func use(camera: AVCaptureDevice?, mic: AVCaptureDevice?, quality: CameraQuality = .best, smooth: Bool = false, phone: PhoneCamera? = nil) {
        queue.async { [self] in
            usePhone(phone)
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

            if let phone {
                let state = phone.state
                onFormat?(state.width > 0 ? CameraFormat(width: state.width, height: state.height, fps: 30) : nil)
            } else {
                onFormat?(camera.flatMap { Self.useFormat($0, quality: quality, fps: smooth ? 60 : 30) })
            }
            if let connection = movie.connection(with: .video) {
                movie.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
            if !taking { frameOutputs.forEach { $0.output.connection(with: .video)?.isEnabled = $0.wanted } }
            // A phone filming another angle has nothing here: its sound comes from the main mic.
            if session.inputs.isEmpty {
                if session.isRunning { session.stopRunning() }
            } else if !resting, !session.isRunning {
                session.startRunning()
            }
        }
    }

    /// Hands every mic buffer to these recorders too: phones filming other angles, recorded with
    /// this recorder's mic. Set on the tap queue, where it is read.
    func shareMic(with recorders: [CameraRecorder]) {
        tapQueue.async { [self] in micTakers = recorders }
    }

    /// A mic buffer for the phone take's file, from this recorder's session or the main one's.
    fileprivate func phoneAudio(_ sample: CMSampleBuffer) {
        guard phoneLock.withLock({ phoneOn }) else { return }
        phoneQueue.async { [self] in
            micFormat = CMSampleBufferGetFormatDescription(sample)
            phoneTake?.audio(sample)
        }
    }

    /// Stops the camera and mic while nobody needs them, or starts them again. A take always wakes
    /// it first, and a resting camera is never stopped in the middle of one.
    func rest(_ on: Bool) {
        queue.async { [self] in
            if on {
                guard !taking, !movie.isRecording else { return }
                resting = true
                phone?.rest(true)
                if session.isRunning { session.stopRunning() }
            } else {
                wake()
            }
        }
    }

    /// Camera queue only. A camera that has just woken gets a second before a file opens on it.
    private func wake() {
        guard resting else { return }
        resting = false
        phone?.rest(false)
        if !session.isRunning, !session.inputs.isEmpty {
            session.startRunning()
            settled = max(settled, CACurrentMediaTime() + 1)
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
            wake()
            frameOutputsOnForTake()
            if let phone {
                // The file opens on the iPhone's next whole picture, which it is asked for now.
                phoneQueue.async { [self] in
                    let take = PhoneTake(url: url)
                    take.micFormat = micFormat
                    phoneTake = take
                }
                phone.askForKeyPicture()
                phone.setRecording(true)
                return
            }
            startedOnce = Once()
            // Give a just-changed session half a second to settle before the file opens.
            let wait = max(0, settled - CACurrentMediaTime())
            queue.asyncAfter(deadline: .now() + wait) { [self] in movie.startRecording(to: url, recordingDelegate: self) }
        }
    }

    /// Switches every extra output on ahead of a take, so nothing about the session changes once
    /// the file is open. Turning one on or off mid-take is what lost a whole camera file on 4 Oct.
    func prepareForTake() {
        queue.async { [self] in
            wake()
            frameOutputsOnForTake()
        }
    }

    /// The take was called off before its file opened: the outputs go back to what they asked for.
    func cancelTake() {
        queue.async { [self] in
            guard !movie.isRecording else { return }
            takeEnded()
        }
    }

    /// Asks for frames to an extra output, or stops them. During a take the change waits until
    /// the file has closed; the output just drops the frames it does not want until then.
    func setFrames(_ output: AVCaptureOutput, on: Bool) {
        queue.async { [self] in
            guard let i = frameOutputs.firstIndex(where: { $0.output === output }) else { return }
            frameOutputs[i].wanted = on
            if !taking { output.connection(with: .video)?.isEnabled = on }
            refreshPhoneTargets()
        }
    }

    /// How many seconds the open movie file holds, or nil when no file is open.
    func written(_ reply: @escaping (Double?) -> Void) {
        queue.async { [self] in
            if phone != nil {
                phoneQueue.async { [self] in reply(phoneTake?.seconds) }
            } else {
                reply(movie.isRecording ? movie.recordedDuration.seconds : nil)
            }
        }
    }

    /// Camera queue only. Switching a connection on means the file waits until `settled`.
    private func frameOutputsOnForTake() {
        taking = true
        // A phone standing by starts sending now, during the 3, 2, 1, so its file can open on time.
        phone?.setTaking(true)
        for item in frameOutputs {
            if let connection = item.output.connection(with: .video), !connection.isEnabled {
                connection.isEnabled = true
                settled = CACurrentMediaTime() + 0.5
            }
        }
        refreshPhoneTargets()
    }

    /// Camera queue only. The take is over, so outputs go back to what they asked for.
    private func takeEnded() {
        taking = false
        phone?.setTaking(false)
        frameOutputs.forEach { $0.output.connection(with: .video)?.isEnabled = $0.wanted }
        refreshPhoneTargets()
    }

    /// Lets go of the camera and mic, for an extra camera that is no longer wanted.
    func release() {
        queue.async { [self] in
            usePhone(nil)
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
            if let phone {
                phone.setRecording(false)
                phoneQueue.async { [self] in
                    let take = phoneTake
                    phoneTake = nil
                    phoneDropped = take?.dropped ?? [:]
                    let done: (Error?) -> Void = { error in self.queue.async { self.takeEnded(); self.onFinished?(error) } }
                    if let take { take.finish(done) } else { done(nil) }
                }
                return
            }
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
            refreshPhoneTargets()
        }
    }

    /// Hands every mic buffer to the voice follower as well. Set on the tap queue, where it is read.
    func forwardAudio(_ handler: ((CMSampleBuffer) -> Void)?) {
        tapQueue.async { [self] in onAudio = handler }
    }

    /// Hands every mic buffer to the live page's Listen as well. Set on the tap queue.
    func streamAudio(_ handler: ((CMSampleBuffer) -> Void)?) {
        tapQueue.async { [self] in onLiveAudio = handler }
    }

    var dimensions: CGSize? {
        guard let device = videoInput?.device else { return nil }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return CGSize(width: Int(d.width), height: Int(d.height))
    }
}

// MARK: - The iPhone over Wi-Fi as the camera

/// A frame output that can also be handed pictures that did not come from a capture session.
protocol FrameTaking: AnyObject {
    func take(_ sampleBuffer: CMSampleBuffer)
}

/// One frame output fed with the iPhone's pictures, on its own queue. A picture is skipped while
/// the one before it is still being handled, as a capture output drops late frames.
private final class PhoneTarget: @unchecked Sendable {
    let taker: FrameTaking
    let queue: DispatchQueue
    private let lock = NSLock()
    private var busy = false

    init(taker: FrameTaking, queue: DispatchQueue) {
        self.taker = taker
        self.queue = queue
    }

    func give(_ sample: CMSampleBuffer) {
        guard lock.withLock({ () -> Bool in defer { busy = true }; return !busy }) else { return }
        queue.async { [self] in
            taker.take(sample)
            lock.withLock { busy = false }
        }
    }
}

extension CameraRecorder {
    /// Camera queue only. Switches a phone in as the camera, or out again.
    fileprivate func usePhone(_ link: PhoneCamera?) {
        guard link !== phone else { return }
        phone?.setTaking(false)
        phone?.stopDelivering(to: self)
        phone = link
        phoneLock.withLock { phoneOn = link != nil }
        guard let link else { return }
        link.deliver(
            to: self,
            compressed: { [weak self] sample in
                guard let self else { return }
                self.phoneQueue.async { self.phoneTake?.video(sample, askForKey: { link.askForKeyPicture() }, started: { time in self.onStarted?(time) }) }
            },
            decoded: { [weak self] sample in
                guard let self else { return }
                for target in self.phoneLock.withLock({ self.phoneTargets }) { target.give(sample) }
            },
            sized: { [weak self] width, height in
                guard let self else { return }
                self.queue.async { self.onFormat?(CameraFormat(width: width, height: height, fps: 30)) }
            })
        link.rest(resting)
        link.start()
        refreshPhoneTargets()
    }

    /// Camera queue only. The outputs that want pictures now. With none, the phone's pictures are
    /// not decoded at all: they only go into the camera file, as they came.
    fileprivate func refreshPhoneTargets() {
        let targets: [PhoneTarget] = phone == nil ? [] : frameOutputs.compactMap { item in
            guard item.wanted, let output = item.output as? AVCaptureVideoDataOutput,
                  let taker = output.sampleBufferDelegate as? FrameTaking, let queue = output.sampleBufferCallbackQueue else { return nil }
            return PhoneTarget(taker: taker, queue: queue)
        }
        phoneLock.withLock { phoneTargets = targets }
        phone?.decode(!targets.isEmpty, for: self)
    }
}

/// camera.mov from the iPhone: its H.264 pictures exactly as they came, and the Mac's mic in AAC,
/// both timed on the Mac's clock. It starts on a whole picture and keeps 2 second fragments, so a
/// crash keeps the take. Phone queue only.
final class PhoneTake {
    private let url: URL
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var videoFormat: CMFormatDescription?
    private var start: CMTime = .invalid
    private var last: CMTime = .invalid
    /// A picture could not be written, so the next ones wait for a whole picture.
    private var broken = false
    /// Pictures and sound the writer is not ready for yet. It takes the two in step, so when
    /// pictures come late over Wi-Fi the sound waits for them here instead of being lost, which
    /// would leave the file's sound shorter than its picture and out of step.
    private var waitingVideo: [CMSampleBuffer] = []
    private var waitingAudio: [CMSampleBuffer] = []
    /// About ten seconds of either; past that the oldest goes.
    private static let mostWaiting = (video: 300, audio: 480)
    var micFormat: CMFormatDescription?
    /// Pictures that did not go into the file, by why, for the take's events.
    private(set) var dropped: [String: Int] = [:]

    init(url: URL) {
        self.url = url
    }

    /// Seconds of pictures written, or nil before the file has opened.
    var seconds: Double? {
        guard start.isValid, last.isValid else { return nil }
        return (last - start).seconds
    }

    func video(_ sample: CMSampleBuffer, askForKey: () -> Void, started: (CFTimeInterval) -> Void) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let key = Self.isKey(sample)
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        if writer == nil {
            guard key, let micFormat else { askForKey(); return }
            guard open(video: format, audio: micFormat, at: time) else { return }
            started(time.seconds)
        }
        guard videoIn != nil, let videoFormat else { return }
        // A different picture shape cannot go into the same file; it waits for the next take.
        guard CMFormatDescriptionEqual(format, otherFormatDescription: videoFormat) else { dropped["another format", default: 0] += 1; return }
        let newest = waitingVideo.last.map(CMSampleBufferGetPresentationTimeStamp) ?? last
        guard !newest.isValid || CMTimeCompare(time, newest) > 0 else { dropped["out of order", default: 0] += 1; return }
        if broken {
            guard key else { dropped["waiting for a whole picture", default: 0] += 1; return }
            broken = false
        }
        waitingVideo.append(sample)
        if waitingVideo.count > Self.mostWaiting.video {
            // Too far behind: what waits goes, and the pictures start again on a whole one.
            dropped["too far behind", default: 0] += waitingVideo.count
            waitingVideo.removeAll()
            broken = true
            askForKey()
        }
        write()
    }

    func audio(_ sample: CMSampleBuffer) {
        if micFormat == nil { micFormat = CMSampleBufferGetFormatDescription(sample) }
        guard audioIn != nil, start.isValid, CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), start) >= 0 else { return }
        waitingAudio.append(sample)
        if waitingAudio.count > Self.mostWaiting.audio { waitingAudio.removeFirst(waitingAudio.count - Self.mostWaiting.audio) }
        write()
    }

    /// Hands the writer whatever it is ready for, oldest first.
    private func write() {
        if let videoIn {
            while let next = waitingVideo.first, videoIn.isReadyForMoreMediaData {
                waitingVideo.removeFirst()
                if videoIn.append(next) {
                    last = CMSampleBufferGetPresentationTimeStamp(next)
                } else {
                    dropped["not written", default: 0] += 1 + waitingVideo.count
                    waitingVideo.removeAll()
                    broken = true
                    break
                }
            }
        }
        if let audioIn {
            while let next = waitingAudio.first, audioIn.isReadyForMoreMediaData {
                waitingAudio.removeFirst()
                audioIn.append(next)
            }
        }
    }

    private func open(video: CMFormatDescription, audio: CMFormatDescription, at time: CMTime) -> Bool {
        do {
            try? FileManager.default.removeItem(at: url)
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            // As the iPhone made them: no second compression.
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: video)
            v.expectsMediaDataInRealTime = true
            guard w.canAdd(v) else { return false }
            w.add(v)
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audio)?.pointee {
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
                let a = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: audio)
                a.expectsMediaDataInRealTime = true
                if w.canAdd(a) { w.add(a); audioIn = a }
            }
            guard w.startWriting() else { return false }
            w.startSession(atSourceTime: time)
            writer = w
            videoIn = v
            videoFormat = video
            start = time
            return true
        } catch {
            return false
        }
    }

    func finish(_ done: @escaping (Error?) -> Void) {
        guard let writer, writer.status == .writing else {
            done(writer == nil ? RecorderError("The phone sent no pictures, so its camera file was not made. Check the phone's page is open.") : writer?.error)
            return
        }
        write()
        videoIn?.markAsFinished()
        audioIn?.markAsFinished()
        if last.isValid { writer.endSession(atSourceTime: last + CMTime(value: 1, timescale: 30)) }
        writer.finishWriting { done(writer.status == .completed ? nil : writer.error) }
    }

    private static func isKey(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    /// The time of camera.mov's first frame, on the host clock. Everything in events.jsonl counts
    /// from it, so a mic file lined up by the clock lands where its sound was.
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, startPTS: CMTime, from connections: [AVCaptureConnection]) {
        guard startedOnce.first() else { return }
        onStarted?(startPTS.isValid ? startPTS.seconds : CACurrentMediaTime())
    }

    /// Older word that the file opened, without its first frame's time. The moment it arrives is
    /// about a fifth of a second after that frame, so it is used only if the timed word never comes.
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let now = CACurrentMediaTime()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            if startedOnce.first() { onStarted?(now) }
        }
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
        onLiveAudio?(sampleBuffer)
        phoneAudio(sampleBuffer)
        for taker in micTakers { taker.phoneAudio(sampleBuffer) }
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

/// Frames the camera dropped before they reached an output, by output and reason, for the self
/// test. "OutOfBuffers" means something held on to the camera's frames too long.
enum FrameDrops {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func note(_ output: String, _ buffer: CMSampleBuffer) {
        let reason = (CMGetAttachment(buffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String) ?? "unknown"
        lock.withLock { counts["\(output): \(reason)", default: 0] += 1 }
    }

    static var report: [String: Int] { lock.withLock { counts } }
}

/// The camera picture for every preview on screen (panel, face box, bubble), from one frame output.
/// Previews used to be AVCaptureVideoPreviewLayers, which belong to the camera session: a window
/// hiding or showing one at the start of a take changed the session and camera.mov stopped within
/// a second. On 4 Oct every test take lost its picture that way, and none did with no preview layers.
/// These layers only get copies of frames, so nothing on screen can touch the session.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, FrameTaking {
    let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "ava.preview")
    private let lock = NSLock()
    private let layers = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()
    /// The layers that can be seen right now. Only these get frames: a hidden layer that kept
    /// taking them would hold on to the camera's buffers, and a camera short of buffers stalls.
    private var seen = Set<ObjectIdentifier>()
    private var handed = 0
    private var frameSize = CGSize(width: 16, height: 9)
    private var nextFrame: (() -> Void)?

    /// Called on the main thread whenever a preview comes into view or the last one goes out of it.
    var onSeenChange: (() -> Void)?

    /// Whether any preview can be seen right now.
    var anySeen: Bool { lock.withLock { !seen.isEmpty } }

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
        let changed = lock.withLock { () -> Bool in
            let before = seen.isEmpty
            if visible { seen.insert(ObjectIdentifier(layer)) } else { seen.remove(ObjectIdentifier(layer)) }
            return before != seen.isEmpty
        }
        if !visible { layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil) }
        if changed { onSeenChange?() }
    }

    /// Runs `action` once, on the preview queue, when the next frame arrives (the camera has woken).
    func whenNextFrame(_ action: @escaping () -> Void) {
        lock.withLock { nextFrame = action }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        FrameDrops.note("preview", sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        take(sampleBuffer)
    }

    func take(_ sampleBuffer: CMSampleBuffer) {
        if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            lock.withLock { frameSize = size }
        }
        if let woke = lock.withLock({ () -> (() -> Void)? in defer { nextFrame = nil }; return nextFrame }) { woke() }
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
/// cut out of the picture. What the Mac plays goes in as a second sound track (the mic stays the
/// first, which the finisher reads): silence while the sound is off, every app's sound, or one app's
/// from a small stream of its own. It can change at any moment of the take.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var systemIn: AVAssetWriterInput?
    /// The Mac's sound: whether it goes in, and from which app (nil is every app). Queue only.
    private var soundOn = false
    private var soundFrom: String?
    /// Where the Mac's sound track has got to, so a change of source never goes back in time. Queue only.
    private var soundEnd = CMTime.invalid
    /// One app's sound, when only that app is wanted.
    private var appStream: SCStream?
    private var display: SCDisplay?
    /// Kept so a shared window that moves can be followed.
    private var config: SCStreamConfiguration?
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

    /// `source` crops to one window's part of the display, in display points.
    func start(filter: SCContentFilter, display: SCDisplay, pixelSize: CGSize, source: CGRect? = nil, micID: String?, to url: URL) async throws {
        self.url = url
        self.display = display
        started = false
        audioFormat = nil
        queue.sync { soundEnd = .invalid }
        size = (Int(pixelSize.width) & ~1, Int(pixelSize.height) & ~1)

        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 8
        if let source { config.sourceRect = source }
        self.config = config
        // The Mac's sound is always listened to, so it can be switched on at any moment; while it is
        // off, silence is written instead. The app's own sounds (the countdown beeps) stay out.
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        wantsAudio = micID != nil
        if let micID {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = micID
        }

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if wantsAudio { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        stream = s
        streamStart = CACurrentMediaTime()
        try await s.startCapture()
    }

    func stop() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        if let a = appStream { try? await a.stopCapture() }
        appStream = nil
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
        // The one-app sound stream only brings sound; its tiny picture is thrown away.
        if stream !== self.stream {
            if type == .audio { takeSound(sampleBuffer, fromOneApp: true) }
            return
        }
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
            takeSound(sampleBuffer, fromOneApp: false)
        default:
            break
        }
    }

    /// Follows a shared window to where it is now.
    func move(source: CGRect) async throws {
        guard let config, let stream else { return }
        config.sourceRect = source
        try await stream.updateConfiguration(config)
    }

    /// Changes what is recorded mid-take, for example to let the face bubble in.
    func update(_ filter: SCContentFilter) async throws {
        try await stream?.updateContentFilter(filter)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The one-app sound stream stops when that app quits; the take carries on.
        if stream === self.stream { onError?(error) }
    }

    /// Turns the Mac's sound on or off, and picks where it comes from: `app` alone, or every app.
    func setSound(on: Bool, app: SCRunningApplication?) async throws {
        let from = app.map(Self.key)
        let changed = queue.sync { () -> Bool in
            soundOn = on
            defer { soundFrom = from }
            return soundFrom != from
        }
        guard changed else { return }
        if let old = appStream {
            appStream = nil
            try? await old.stopCapture()
        }
        guard let app, let display else { return }
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        let s = SCStream(filter: SCContentFilter(display: display, including: [app], exceptingWindows: []),
                         configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        appStream = s
        try await s.startCapture()
    }

    /// How an app is told apart: its bundle id, or its name when it has none.
    static func key(_ app: SCRunningApplication) -> String {
        app.bundleIdentifier.isEmpty ? app.applicationName : app.bundleIdentifier
    }

    /// Queue only. Writes the Mac's sound from the chosen source, or silence in its place while off.
    private func takeSound(_ buffer: CMSampleBuffer, fromOneApp: Bool) {
        guard started, let input = systemIn, fromOneApp == (soundFrom != nil) else { return }
        let time = buffer.presentationTimeStamp
        if soundEnd.isValid, CMTimeCompare(time, soundEnd) < 0 { return }
        guard input.isReadyForMoreMediaData, let out = soundOn ? buffer : Self.silence(like: buffer) else { return }
        if input.append(out) { soundEnd = CMTimeAdd(time, buffer.duration) }
    }

    /// A buffer of silence with the same format, length and time.
    private static func silence(like buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let format = buffer.formatDescription, let data = buffer.dataBuffer else { return nil }
        let length = CMBlockBufferGetDataLength(data)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr
        else { return nil }
        var out: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: buffer.numSamples, presentationTimeStamp: buffer.presentationTimeStamp,
                                                             packetDescriptions: nil, sampleBufferOut: &out)
        return out
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
            do {
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
