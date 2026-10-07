import AVFoundation
import Speech

/// Hears the presenter through the mic the app already records, entirely on this Mac: no audio or text
/// leaves it. SpeechAnalyzer on macOS 26 when an English model is installed, otherwise
/// SFSpeechRecognizer limited to on-device recognition. It can never stop a take: a failure is
/// reported once through onFail and the listener goes quiet.
final class Listener: @unchecked Sendable {
    /// Everything heard since start, the newest words still settling. Called on a background queue.
    var onWords: (([String]) -> Void)?
    var onFail: ((String) -> Void)?
    private(set) var name = ""

    private let queue = DispatchQueue(label: "vidlark.listen")
    private let lock = NSLock()
    private var engine: ListenEngine?
    private var converter: AVAudioConverter?
    private var settled: [String] = []
    private var settling: [String] = []
    private var failed = false
    private var stopped = false

    private enum Choice {
        case analyzer(Locale)
        case legacy(Locale)
    }

    /// Asks once for speech recognition. Without the usage text in Info.plist the system would
    /// end the app, so a bare build counts as not allowed.
    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else { done(false); return }
        SFSpeechRecognizer.requestAuthorization { done($0 == .authorized) }
    }

    /// Whether this Mac can listen without going online.
    static func available() async -> Bool { await choose() != nil }

    /// Indian English first, then US English. Only models already on the Mac:
    /// fetching one would go online. Reserving a locale is local bookkeeping that lets the app use it.
    private static func choose() async -> Choice? {
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            let installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
            for id in ["en-IN", "en-US"] {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)),
                      installed.contains(locale.identifier) else { continue }
                let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
                if await AssetInventory.status(forModules: [module]) != .installed {
                    _ = try? await AssetInventory.reserve(locale: locale)
                }
                if await AssetInventory.status(forModules: [module]) == .installed { return .analyzer(locale) }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return nil }
        for id in ["en-IN", "en-US"] {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.supportsOnDeviceRecognition, r.isAvailable {
                return .legacy(r.locale)
            }
        }
        return nil
    }

    func start() async throws {
        guard let choice = await Self.choose() else { throw RecorderError("No on-device speech model is installed.") }
        let started: ListenEngine
        switch choice {
        case .analyzer(let locale):
            guard #available(macOS 26.0, *) else { throw RecorderError("SpeechAnalyzer needs macOS 26.") }
            started = try await AnalyzerEngine(locale: locale, listener: self)
            name = "SpeechAnalyzer \(locale.identifier)"
        case .legacy(let locale):
            started = try LegacyEngine(locale: locale, listener: self, queue: queue)
            name = "SFSpeechRecognizer \(locale.identifier), on device"
        }
        queue.sync { engine = started }
    }

    /// A buffer from the capture queue. The copy is quick; converting and recognising happen elsewhere.
    func feed(_ sample: CMSampleBuffer) {
        guard let buffer = Self.pcm(sample) else { return }
        feed(buffer)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard let engine, !failed, let converted = convert(buffer, to: engine.format) else { return }
            engine.append(converted)
        }
    }

    /// Quiet at once: nothing more is reported after this.
    func stop() {
        lock.withLock { stopped = true }
        queue.async { [self] in
            guard let engine else { return }
            self.engine = nil
            Task { await engine.stop(finishing: false) }
        }
    }

    /// Lets the last words settle, for the file test.
    func finish() async {
        let current: ListenEngine? = queue.sync { let e = engine; engine = nil; return e }
        await current?.stop(finishing: true)
    }

    var words: [String] { lock.withLock { settled + settling } }

    // MARK: From the engines

    fileprivate func draft(_ text: String) {
        let all: [String]? = lock.withLock {
            settling = text.split(whereSeparator: \.isWhitespace).map(String.init)
            return stopped ? nil : settled + settling
        }
        if let all { onWords?(all) }
    }

    fileprivate func settle(_ text: String) {
        let all: [String]? = lock.withLock {
            settled += text.split(whereSeparator: \.isWhitespace).map(String.init)
            settling = []
            return stopped ? nil : settled + settling
        }
        if let all { onWords?(all) }
    }

    fileprivate func fail(_ error: Error) {
        let first: Bool = lock.withLock { defer { failed = true }; return !failed && !stopped }
        if first { onFail?(error.localizedDescription) }
    }

    // MARK: Audio

    static func pcm(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr else { return nil }
        return buffer
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }
}

private protocol ListenEngine: AnyObject {
    var format: AVAudioFormat { get }
    func append(_ buffer: AVAudioPCMBuffer)
    func stop(finishing: Bool) async
}

// MARK: - SpeechAnalyzer (macOS 26)

@available(macOS 26.0, *)
private final class AnalyzerEngine: ListenEngine {
    let format: AVAudioFormat
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var reader: Task<Void, Never>?

    init(locale: Locale, listener: Listener) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw RecorderError("No audio format for speech.")
        }
        self.format = format
        // Bounded, so a slow moment drops old audio instead of growing without end.
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(400))
        self.input = input
        analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)
        reader = Task { [weak listener] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal { listener?.settle(text) } else { listener?.draft(text) }
                }
            } catch {
                listener?.fail(error)
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    func stop(finishing: Bool) async {
        input.finish()
        if finishing {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await reader?.value
        } else {
            await analyzer.cancelAndFinishNow()
        }
    }
}

// MARK: - SFSpeechRecognizer (before macOS 26)

/// One recognition task at a time, restarted every 50 seconds so it never meets a duration limit.
private final class LegacyEngine: ListenEngine {
    let format: AVAudioFormat
    private let recognizer: SFSpeechRecognizer
    private let queue: DispatchQueue
    private weak var listener: Listener?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var began: CFTimeInterval = 0
    private var draft = ""
    private var errors: [CFTimeInterval] = []

    init(locale: Locale, listener: Listener, queue: DispatchQueue) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw RecorderError("On-device speech is not available.")
        }
        self.recognizer = recognizer
        self.listener = listener
        self.queue = queue
        format = SFSpeechAudioBufferRecognitionRequest().nativeAudioFormat
        queue.async { [self] in begin() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if CACurrentMediaTime() - began > 50 { restart() }
        request?.append(buffer)
    }

    func stop(finishing: Bool) async {
        queue.sync {
            generation += 1
            if finishing { request?.endAudio() } else { task?.cancel() }
            request = nil
            task = nil
        }
    }

    private func begin() {
        generation += 1
        let mine = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        began = CACurrentMediaTime()
        draft = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = result?.isFinal ?? false
            self?.queue.async { self?.took(mine, text, done, error) }
        }
    }

    private func took(_ from: Int, _ text: String?, _ done: Bool, _ error: Error?) {
        guard from == generation else { return }
        if let text {
            draft = text
            listener?.draft(text)
        }
        guard done || error != nil else { return }
        listener?.settle(draft)
        draft = ""
        if let error {
            // A task that heard nothing ends with an error; only a run of them is a real failure.
            let now = CACurrentMediaTime()
            errors = errors.filter { now - $0 < 30 } + [now]
            if errors.count >= 6 { listener?.fail(error); return }
        }
        begin()
    }

    private func restart() {
        listener?.settle(draft)
        request?.endAudio()
        task?.cancel()
        begin()
    }
}

// MARK: - File test (`--test-follow <audio file or transcript.txt> <script.md>`)

/// Runs the take's listener and follower on a file instead of the mic, paced in real time, and
/// prints every move. A .txt file is read as a transcript instead, at about 150 words a minute,
/// with `[pause 2]` for two seconds of silence and `#` lines ignored.
enum FollowTest {
    @MainActor
    static func run(source: String, script path: String) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("could not read \(path)")
            exit(1)
        }
        let script = Script.parse(text, fallbackTitle: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        let done = Flag()
        Task.detached {
            do {
                if source.lowercased().hasSuffix(".txt") { try runText(source, script) } else { try await runAudio(source, script) }
            } catch {
                print("failed: \((error as? RecorderError)?.message ?? error.localizedDescription)")
                done.code = 1
            }
            done.set()
        }
        while !done.value { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        exit(done.code)
    }

    private static func runAudio(_ source: String, _ script: Script) async throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: source))
        let format = file.processingFormat
        let listener = Listener()
        listener.onFail = { print("listen-error \($0)") }
        try await listener.start()
        let seconds = Double(file.length) / format.sampleRate
        var run = Run(script, header: "\(URL(fileURLWithPath: source).lastPathComponent), \(String(format: "%.1f", seconds)) s, \(listener.name)")

        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        let began = CACurrentMediaTime()
        var fed = 0.0
        func pace() async {
            let ahead = fed - (CACurrentMediaTime() - began)
            if ahead > 0 { try? await Task.sleep(nanoseconds: UInt64(ahead * 1_000_000_000)) }
        }
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            listener.feed(buffer)
            fed += Double(buffer.frameLength) / format.sampleRate
            // The same test as the panel's mic lamp: louder than -45 dB is her voice.
            if level(buffer) > -45 { run.loudAt = fed }
            await pace()
            run.step(listener.words, at: fed)
        }
        // Two seconds of silence, as after the last line of a take.
        for _ in 0..<20 {
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            silence.frameLength = chunk
            listener.feed(silence)
            fed += Double(chunk) / format.sampleRate
            await pace()
            run.step(listener.words, at: fed)
        }
        await listener.finish()
        run.step(listener.words, at: fed)
        run.close(listener.words)
    }

    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -160 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[0][i] * data[0][i] }
        return 10 * log10(max(sum / Float(buffer.frameLength), 1e-16))
    }

    private static func runText(_ source: String, _ script: Script) throws {
        let text = try String(contentsOfFile: source, encoding: .utf8)
        var timed: [(word: String, t: Double)] = []
        var t = 1.0
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("[pause"), let n = Double(trimmed.dropFirst(6).dropLast().trimmingCharacters(in: .whitespaces)) {
                t += n
                continue
            }
            for word in trimmed.split(separator: " ") {
                t += 0.4
                timed.append((String(word), t))
            }
        }
        var run = Run(script, header: "\(URL(fileURLWithPath: source).lastPathComponent), transcript at 150 words a minute")
        var now = 0.0
        while now < t + 3 {
            now += 0.1
            let said = timed.filter { $0.t <= now }
            if let last = said.last, now - last.t < 0.4 { run.loudAt = now }
            run.step(said.map(\.word), at: now)
        }
        run.close(timed.map(\.word))
    }

    /// The follower plus the printout, shared by both kinds of test.
    private struct Run {
        var follower: Follower
        var last: [String] = []
        var moves = 0
        var loudAt = -Double.infinity
        let script: Script

        init(_ script: Script, header: String) {
            self.script = script
            follower = Follower(cards: script.cards, title: script.title)
            follower.show(0, at: 0)
            print("follow test: \(header)")
            print("script: \(script.title), \(script.cards.count) cards (numbered from 1, as in events.jsonl)")
            for (i, card) in script.cards.enumerated() {
                print(String(format: "  %2d  %@  ", i + 1, card.prose ? "prose " : "bullet") + card.text)
            }
            print("")
            print("   0.0 s  card 1 shown")
        }

        mutating func step(_ words: [String], at t: Double) {
            let move = words != last ? follower.hear(words, at: t, loudAt: loudAt) : follower.tick(at: t, loudAt: loudAt)
            last = words
            guard let to = move else { return }
            moves += 1
            let from = follower.index
            let context = words.suffix(8).joined(separator: " ")
            let target = to < script.cards.count ? "card \(to + 1)" : "end"
            print(String(format: "%6.1f s  ", t) + "card \(from + 1) -> \(target)  by voice   heard: \"...\(context)\"")
            follower.show(to, at: t)
        }

        func close(_ words: [String]) {
            print("")
            print("moves: \(moves), finished on \(follower.index < script.cards.count ? "card \(follower.index + 1)" : "the end")")
            print("heard: \(words.joined(separator: " "))")
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var code: Int32 = 0
        var value: Bool { lock.withLock { done } }
        func set() { lock.withLock { done = true } }
    }
}
