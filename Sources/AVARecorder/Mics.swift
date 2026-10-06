import AVFoundation
import CoreAudio

// More microphones. The main mic goes into camera.mov (and screen.mov) as before; each mic added
// next to it records its own file, mic-2.m4a, mic-3.m4a and on: a mic the Mac sees (a USB mic, a
// wireless kit's receiver, AirPods) or a phone's mic over Wi-Fi. All are timed on the Mac's clock
// and the finisher lines each up with camera.mov by sound, so any of them can be the video's sound.

/// One more microphone, recorded to its own file. Its level shows in the panel while it is awake.
final class MicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Source {
        case device(AVCaptureDevice)
        case phone(PhoneCamera)
    }

    /// The level, and whether it has been heard lately, for the panel. Updated on the main thread.
    let meter = LevelMeter()
    let heard = MicHeard()
    private let queue = DispatchQueue(label: "ava.mic")
    private let output = AVCaptureAudioDataOutput()
    // Queue only.
    private var session: AVCaptureSession?
    private var source: Source?
    private var resting = false
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var format: CMAudioFormatDescription?
    private var url: URL?
    /// From the take's start until its stop: sound from `from` until `until` goes into the file.
    private var from: CMTime = .invalid
    private var until: CMTime = .invalid
    /// Where the file's sound has got to, so every batch follows straight on from the last.
    private var next: CMTime = .invalid
    /// The host time of the file's first sample.
    private var opened: CMTime = .invalid
    private var lastLevel: CFTimeInterval = 0
    private var lastLoud: CFTimeInterval = 0

    override init() {
        super.init()
        // 16-bit samples whatever the mic, so the level, the gaps and the file are worked out one way.
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                                AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Listens to this mic from now on, between takes too, so its level shows.
    func use(_ source: Source) {
        queue.async { [self] in
            stopListening()
            self.source = source
            switch source {
            case .device(let device):
                let s = AVCaptureSession()
                s.beginConfiguration()
                if let input = try? AVCaptureDeviceInput(device: device), s.canAddInput(input) { s.addInput(input) }
                if s.canAddOutput(output) { s.addOutput(output) }
                s.commitConfiguration()
                session = s
                if !resting { s.startRunning() }
            case .phone(let phone):
                phone.listen(self) { [weak self] sample in self?.queue.async { self?.heard(sample) } }
                phone.rest(resting)
                phone.start()
            }
        }
    }

    /// Lets go of the mic, for one that is no longer wanted.
    func release() {
        queue.async { [self] in
            stopListening()
            source = nil
        }
    }

    /// Queue only.
    private func stopListening() {
        if let session {
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
        }
        session = nil
        if case .phone(let phone) = source { phone.listen(self, nil) }
        level(nil)
    }

    /// Stops listening while nobody needs the mic, with the rest of the camera and mic.
    func rest(_ on: Bool) {
        queue.async { [self] in
            guard url == nil || !on else { return }
            resting = on
            switch source {
            case .device: if on { session?.stopRunning(); level(nil) } else if session?.isRunning == false { session?.startRunning() }
            case .phone(let phone): phone.rest(on); if on { level(nil) }
            case nil: break
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        heard(sampleBuffer)
    }

    // MARK: The file

    /// The file opens on the first sound from now on.
    func startRecording(to url: URL) {
        queue.async { [self] in
            if resting { rest(false) }
            self.url = url
            writer = nil
            input = nil
            format = nil
            next = .invalid
            until = .invalid
            from = CMClockGetTime(CMClockGetHostTimeClock())
            if case .phone(let phone) = source { phone.setRecording(true) }
        }
    }

    /// The take stopped at `time`: nothing after it goes in, though the file closes a moment later.
    func end(at time: CMTime) {
        queue.async { [self] in
            guard url != nil else { return }
            until = time
            if case .phone(let phone) = source { phone.setRecording(false) }
        }
    }

    /// Closes the file. Sound from a phone is a moment behind, so it gets that moment to arrive; the
    /// file then runs on in silence to the stop, so a mic muted near the end still covers the take.
    /// Without any sound in the take there is no file, and the error says why. `done` also gets the
    /// host time the file's first sample was heard, which lines the file up when sound cannot.
    func stopRecording(_ done: @escaping (Error?, CFTimeInterval?) -> Void) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var late = 0.0
        if case .phone = source { late = 0.6 }
        queue.asyncAfter(deadline: .now() + late) { [self] in
            let name = url?.lastPathComponent ?? "the mic file"
            let stop = until.isValid ? until : now
            if case .phone(let phone) = source { phone.setRecording(false) }
            url = nil
            from = .invalid
            until = .invalid
            let began = opened.isValid ? opened.seconds : nil
            opened = .invalid
            guard let writer, writer.status == .writing, let input else {
                let error = writer?.error ?? RecorderError("No sound came from this mic during the take, so \(name) was not made.")
                self.writer = nil
                done(error, nil)
                return
            }
            silence(until: stop)
            input.markAsFinished()
            writer.endSession(atSourceTime: stop)
            self.writer = nil
            self.input = nil
            writer.finishWriting { done(writer.status == .completed ? nil : writer.error, began) }
        }
    }

    /// Queue only. One batch of sound: its level for the panel, then into the file during a take.
    private func heard(_ sample: CMSampleBuffer) {
        level(sample)
        guard url != nil, from.isValid else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return }
        let duration = CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(sample)), timescale: CMTimeScale(rate(description)))
        // Sound from before the take began, or after it stopped, stays out.
        guard (time + duration) > from, !until.isValid || time < until else { return }
        if writer == nil {
            guard open(description, at: time) else { return }
        }
        guard let input, let format, CMFormatDescriptionEqual(description, otherFormatDescription: format) else { return }
        // Follow straight on from the last batch: a gap (a phone's Wi-Fi, a mute) becomes silence,
        // an overlap is dropped, and anything within a few milliseconds is taken as on time.
        let gap = (time - next).seconds
        if gap < -0.03 { return }
        if gap > 0.03 { silence(until: time) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate(format))),
                                        presentationTimeStamp: next, decodeTimeStamp: .invalid)
        var moved: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing, sampleBufferOut: &moved) == noErr, let moved else { return }
        if input.isReadyForMoreMediaData, input.append(moved) {
            next = next + CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(sample)), timescale: CMTimeScale(rate(format)))
        }
    }

    private func rate(_ format: CMAudioFormatDescription) -> Double {
        CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate ?? 48_000
    }

    /// Queue only. AAC, as in camera.mov: at most 48 kHz, mono or stereo.
    private func open(_ description: CMAudioFormatDescription, at time: CMTime) -> Bool {
        guard let url, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return false }
        do {
            try? FileManager.default.removeItem(at: url)
            let w = try AVAssetWriter(outputURL: url, fileType: .m4a)
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
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: description)
            a.expectsMediaDataInRealTime = true
            guard w.canAdd(a) else { return false }
            w.add(a)
            guard w.startWriting() else { return false }
            w.startSession(atSourceTime: time)
            writer = w
            input = a
            format = description
            next = time
            opened = time
            return true
        } catch {
            return false
        }
    }

    /// Queue only. Silence from where the file has got to until `time`, a second at a time.
    private func silence(until time: CMTime) {
        guard let input, let format, next.isValid, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }
        let rate = asbd.mSampleRate, bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        var left = Int(((time - next).seconds * rate).rounded())
        // Never more than an hour, whatever the clocks say.
        left = min(left, Int(rate) * 3600)
        while left > 0 {
            let frames = min(left, Int(rate))
            var block: CMBlockBuffer?
            let length = frames * bytesPerFrame
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                     blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                     dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                     blockBufferOut: &block) == noErr, let block,
                  CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr else { return }
            var quiet: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames,
                presentationTimeStamp: next, packetDescriptions: nil, sampleBufferOut: &quiet) == noErr, let quiet else { return }
            // A long stretch of silence goes in faster than the encoder takes it: wait for it, briefly.
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 1000 { usleep(2000); waited += 1 }
            guard input.isReadyForMoreMediaData, input.append(quiet) else { return }
            next = next + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
            left -= frames
        }
    }

    // MARK: Level

    /// Queue only. The loudest sample and the average, about 15 times a second; nil clears it.
    private func level(_ sample: CMSampleBuffer?) {
        guard let sample else {
            DispatchQueue.main.async { [meter] in meter.level = -160; meter.peak = -160 }
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastLevel > 0.066, let block = CMSampleBufferGetDataBuffer(sample),
              let asbd = CMSampleBufferGetFormatDescription(sample).flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }),
              asbd.mBitsPerChannel == 16 else { return }
        lastLevel = now
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let count = length / 2
        guard count > 0 else { return }
        var peak: Int32 = 0
        var sum: Double = 0
        pointer.withMemoryRebound(to: Int16.self, capacity: count) { samples in
            for i in 0..<count {
                let v = Int32(samples[i])
                peak = max(peak, abs(v))
                sum += Double(v) * Double(v)
            }
        }
        let rms = (sum / Double(count)).squareRoot()
        let average = rms > 0 ? Float(20 * log10(rms / 32768)) : -160
        let top = peak > 0 ? Float(20 * log10(Double(peak) / 32768)) : -160
        if average > -45 { lastLoud = now }
        let loud = now - lastLoud < 8
        DispatchQueue.main.async { [meter, heard] in
            meter.level = average
            meter.peak = top
            if heard.recently != loud { heard.recently = loud }
        }
    }
}
