import AVFoundation
import AppKit
import CoreImage
import Network
import Security
import SystemConfiguration

// Live view: a web page for another laptop or phone that shows every camera, the screen while
// recording, the mic level and the checks, so whoever runs the shoot can see it is working.
// The Mac serves the page itself. A long secret in the link is the only key, so there is no login.
// "Anywhere" puts a Cloudflare quick tunnel in front of it so the link also works outside the home.

enum LiveMode: String {
    case off, wifi, anywhere
}

// MARK: - Pictures

/// The latest JPEG of each stream. Nothing is encoded unless the page asked in the last 3 seconds.
final class LiveFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var jpegs: [String: Data] = [:]
    private var asked: [String: CFTimeInterval] = [:]
    private var made: [String: CFTimeInterval] = [:]
    private var encoder: CIContext?
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Called on the server queue when a stream nobody was watching is asked for again.
    var onWake: ((String) -> Void)?

    func watching(_ name: String) -> Bool {
        lock.withLock { CACurrentMediaTime() - (asked[name] ?? 0) < 3 }
    }

    func take(_ name: String) -> Data? {
        let (data, wasIdle) = lock.withLock { () -> (Data?, Bool) in
            let now = CACurrentMediaTime()
            let idle = now - (asked[name] ?? 0) >= 3
            asked[name] = now
            return (jpegs[name], idle)
        }
        if wasIdle { onWake?(name) }
        return data
    }

    /// Encodes this frame when someone is watching and the last one is older than `interval`.
    func offer(_ name: String, _ pixels: CVPixelBuffer, maxWidth: CGFloat, interval: CFTimeInterval) {
        let now = CACurrentMediaTime()
        let due = lock.withLock { () -> Bool in
            guard now - (asked[name] ?? 0) < 3, now - (made[name] ?? 0) >= interval else { return false }
            made[name] = now
            return true
        }
        guard due else { return }
        var image = CIImage(cvPixelBuffer: pixels)
        if image.extent.width > maxWidth {
            let k = maxWidth / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        }
        // Made on first use, so the app carries no image encoder until someone watches.
        let context = lock.withLock { () -> CIContext in
            if let encoder { return encoder }
            let made = CIContext(options: [.cacheIntermediates: false])
            encoder = made
            return made
        }
        let quality = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.6]
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: sRGB, options: quality) else { return }
        lock.withLock { jpegs[name] = jpeg }
    }

    func forget(_ name: String) {
        lock.withLock { jpegs[name] = nil }
    }
}

/// A copy of one camera's picture for the page. Its connection is switched off unless someone watches.
final class LiveTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let output = AVCaptureVideoDataOutput()
    let name: String
    /// The camera this tap is attached to. Frames are switched on and off through it.
    weak var camera: CameraRecorder?
    private let frames: LiveFrames
    private let queue: DispatchQueue
    private var asleep = false

    init(name: String, frames: LiveFrames) {
        self.name = name
        self.frames = frames
        queue = DispatchQueue(label: "ava.live.\(name)")
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func wake() {
        queue.async { [self] in asleep = false }
        camera?.setFrames(output, on: true)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard frames.watching(name) else {
            if !asleep { asleep = true; camera?.setFrames(output, on: false) }
            return
        }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frames.offer(name, pixels, maxWidth: 960, interval: 1.0 / 8)
    }
}

// MARK: - Sound

/// The mic as it is being recorded, for whoever presses Listen on the page, to hear echo, hum or
/// a loose cable through headphones. 24 kHz, mono, 16 bit, sent as it arrives. Nothing is
/// converted while nobody listens.
final class LiveAudio: @unchecked Sendable {
    static let sampleRate = 24_000.0
    private let lock = NSLock()
    private var listeners: [ObjectIdentifier: NWConnection] = [:]
    /// Bytes sent to each listener and not yet taken. A listener more than 2 seconds behind is dropped.
    private var inFlight: [ObjectIdentifier: Int] = [:]
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: LiveAudio.sampleRate, channels: 1, interleaved: true)!
    /// Called when the first listener arrives, so a resting mic wakes.
    var onFirstListener: (() -> Void)?

    var listening: Bool { lock.withLock { !listeners.isEmpty } }

    func add(_ connection: NWConnection) {
        let first = lock.withLock { () -> Bool in
            defer { listeners[ObjectIdentifier(connection)] = connection; inFlight[ObjectIdentifier(connection)] = 0 }
            return listeners.isEmpty
        }
        if first { onFirstListener?() }
    }

    func remove(_ connection: NWConnection) {
        lock.withLock {
            listeners[ObjectIdentifier(connection)] = nil
            inFlight[ObjectIdentifier(connection)] = nil
        }
        connection.cancel()
    }

    func closeAll() {
        let all = lock.withLock { () -> [NWConnection] in defer { listeners = [:]; inFlight = [:] }; return Array(listeners.values) }
        all.forEach { $0.cancel() }
    }

    /// One mic buffer, from the camera's tap queue.
    func offer(_ sample: CMSampleBuffer) {
        guard listening, let pcm = convert(sample), !pcm.isEmpty else { return }
        // One HTTP chunk: its length in hex, the bytes, a line end.
        let chunk = Data(String(pcm.count, radix: 16).utf8) + Data("\r\n".utf8) + pcm + Data("\r\n".utf8)
        let targets = lock.withLock { () -> [(NWConnection, Bool)] in
            listeners.map { id, connection in
                let behind = (inFlight[id] ?? 0) > Int(Self.sampleRate) * 2 * 2
                if !behind { inFlight[id, default: 0] += chunk.count }
                return (connection, behind)
            }
        }
        for (connection, behind) in targets {
            if behind { remove(connection); continue }
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.remove(connection); return }
                self.lock.withLock { if self.inFlight[ObjectIdentifier(connection)] != nil { self.inFlight[ObjectIdentifier(connection)]! -= chunk.count } }
            })
        }
    }

    private func convert(_ sample: CMSampleBuffer) -> Data? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var asbd = basic.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        if source != format {
            source = format
            converter = AVAudioConverter(from: format, to: target)
            converter?.downmix = true
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard let converter, frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        input.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr,
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(frames) * Self.sampleRate / format.sampleRate) + 64)
        else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let samples = output.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: Int(output.frameLength) * 2)
    }
}

// MARK: - Server

/// A tiny web server on port 8790. Every address starts with the secret; anything else is "not found".
final class LiveServer: @unchecked Sendable {
    static let port: UInt16 = 8790
    private let frames: LiveFrames
    private let audio: LiveAudio
    private let queue = DispatchQueue(label: "ava.live.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var secret: String
    /// Builds the status JSON. Called on the main thread.
    var status: (() -> Data)?
    /// Why the server stopped, for example the port is taken. Called on the server queue.
    var onFailure: ((String) -> Void)?

    init(frames: LiveFrames, audio: LiveAudio, token: String) {
        self.frames = frames
        self.audio = audio
        secret = token
    }

    var token: String {
        get { lock.withLock { secret } }
        set { lock.withLock { secret = newValue } }
    }

    var isRunning: Bool { lock.withLock { listener != nil } }

    func start() throws {
        guard !isRunning else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let l = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
        l.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.stop()
                self?.onFailure?(error.localizedDescription)
            }
        }
        l.start(queue: queue)
        lock.withLock { listener = l }
    }

    func stop() {
        lock.withLock { listener?.cancel(); listener = nil }
        audio.closeAll()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil || buffer.count > 16_384 {
                connection.cancel()
            } else {
                self.read(connection, buffer)
            }
        }
    }

    private func answer(_ connection: NWConnection, head: String) {
        let words = head.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ") ?? []
        guard words.count >= 2, words[0] == "GET" else {
            return send(connection, 405, "text/plain", Data("Not allowed".utf8))
        }
        let path = words[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first, Self.same(first, token) else {
            return send(connection, 404, "text/plain", Data("Not found".utf8))
        }
        let rest = parts.dropFirst().joined(separator: "/")
        if rest.isEmpty {
            send(connection, 200, "text/html; charset=utf-8", Data(LivePage.html.utf8))
        } else if rest == "status" {
            DispatchQueue.main.async { [self] in
                let body = status?() ?? Data("{}".utf8)
                queue.async { self.send(connection, 200, "application/json", body) }
            }
        } else if rest == "audio" {
            // Stays open, sending the mic as it arrives, until the page stops listening.
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n"
                + "Cache-Control: no-store\r\nX-Accel-Buffering: no\r\nReferrer-Policy: no-referrer\r\nX-Robots-Tag: noindex\r\n"
                + "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.audio.remove(connection)
                default: break
                }
            }
            connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
                if error == nil { self?.audio.add(connection) } else { connection.cancel() }
            })
        } else if rest.hasPrefix("frame/"), rest.hasSuffix(".jpg") {
            let name = String(rest.dropFirst(6).dropLast(4))
            if let jpeg = frames.take(name) {
                send(connection, 200, "image/jpeg", jpeg)
            } else {
                send(connection, 204, "text/plain", Data())
            }
        } else {
            send(connection, 404, "text/plain", Data("Not found".utf8))
        }
    }

    private func send(_ connection: NWConnection, _ code: Int, _ type: String, _ body: Data) {
        let reason = [200: "OK", 204: "No Content", 404: "Not Found", 405: "Method Not Allowed"][code] ?? "OK"
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Robots-Tag: noindex\r\n"
            + "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Compares every character, so timing does not give the secret away.
    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The Mac's name on the home network, such as Your-Mac.local.
    static var localAddress: String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String? else { return nil }
        return "http://\(name).local:\(port)"
    }
}

// MARK: - Tunnel

/// A Cloudflare quick tunnel: a random https address that reaches this Mac from anywhere, with
/// no account. The address changes every time the tunnel starts.
final class Tunnel {
    static var binary: String? {
        ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var process: Process?
    /// The public address once it is up, nil when it stops. Called on the main thread.
    var onAddress: ((String?) -> Void)?

    var isRunning: Bool { process != nil }

    func start() {
        guard process == nil, let binary = Self.binary else { return }
        Self.closeLeftover()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(LiveServer.port)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // The address shows up about 10 seconds before it works. Hand it out only once Cloudflare
        // says the connection is registered, so a copied link never opens to an error.
        let found = Once()
        var address: String?
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if address == nil, let range = text.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) {
                address = String(text[range])
            }
            if let address, text.contains("Registered tunnel connection"), found.first() {
                DispatchQueue.main.async { self?.onAddress?(address) }
            }
        }
        p.terminationHandler = { [weak self] ended in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                self.process = nil
                self.onAddress?(nil)
            }
        }
        do {
            try p.run()
            process = p
            UserDefaults.standard.set(Int(p.processIdentifier), forKey: "tunnelPID")
        } catch {
            onAddress?(nil)
        }
    }

    func stop() {
        let p = process
        process = nil
        p?.terminate()
        UserDefaults.standard.removeObject(forKey: "tunnelPID")
    }

    /// A tunnel left behind by a crash would keep running; close it before opening a new one.
    private static func closeLeftover() {
        let pid = pid_t(UserDefaults.standard.integer(forKey: "tunnelPID"))
        UserDefaults.standard.removeObject(forKey: "tunnelPID")
        guard pid > 0 else { return }
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path).hasSuffix("/cloudflared") {
            kill(pid, SIGTERM)
        }
    }
}

// MARK: - Page

enum LivePage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<meta name="referrer" content="no-referrer">
<title>AVA Live</title>
<style>
:root {
  --body: #0E1110; --face: #151917; --raised: #1C211F; --well: #070908; --hair: rgba(255,255,255,.075);
  --ink: #ECF1EE; --dim: #A3ADA8; --engraved: #86918B;
  --signal: #3DCC80; --amber: #E8B34B; --red: #F04E3E;
}
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--body); color: var(--ink);
  font: 14px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif; }
button { font: inherit; color: inherit; }
main { max-width: 1400px; margin: 0 auto; padding: 20px 16px 32px; }
header { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; margin-bottom: 16px; }
.state { display: flex; align-items: center; gap: 10px; font-size: 20px; font-weight: 500; }
.dot { width: 11px; height: 11px; border-radius: 50%; background: var(--engraved); flex: none; }
.dot.rec { background: var(--red); animation: pulse 1.4s ease-in-out infinite; }
.dot.ok { background: var(--signal); }
.dot.warn { background: var(--amber); }
@keyframes pulse { 50% { opacity: .35; } }
@media (prefers-reduced-motion: reduce) { .dot.rec { animation: none; } }
.time { font-variant-numeric: tabular-nums; color: var(--ink); }
.title { color: var(--dim); font-size: 14px; flex: 1 1 200px; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.meter { display: flex; align-items: center; gap: 8px; color: var(--engraved); font-size: 11px; letter-spacing: .12em; text-transform: uppercase; }
.bar { width: 120px; height: 6px; border-radius: 3px; background: var(--well); overflow: hidden; }
.bar i { display: block; height: 100%; width: 0; background: var(--signal); transition: width .2s linear; }
.bar i.hot { background: var(--amber); }
.listen { display: inline-flex; align-items: center; gap: 8px; height: 34px; padding: 0 14px 0 12px; border-radius: 17px;
  border: 1px solid var(--hair); background: var(--raised); cursor: pointer; font-size: 13px; font-weight: 600; }
.listen:hover { border-color: rgba(255,255,255,.18); }
.listen:focus-visible, figure .pic:focus-visible, .chip:focus-visible { outline: 2px solid var(--signal); outline-offset: 2px; }
.listen svg { width: 16px; height: 16px; flex: none; }
.listen.on { background: rgba(61,204,128,.14); border-color: rgba(61,204,128,.5); color: var(--signal); }
.listen[disabled] { opacity: .45; cursor: default; }
.hint { width: 100%; margin: -6px 0 0; color: var(--dim); font-size: 12.5px; }
.hint[hidden] { display: none; }
.grid { display: grid; grid-template-columns: minmax(0, 2fr) minmax(0, 1fr); gap: 12px; align-items: start; }
.side { display: grid; gap: 12px; }
.grid:has(.side:empty) { grid-template-columns: minmax(0, 1fr); max-width: 980px; }
@media (max-width: 800px) { .grid { grid-template-columns: minmax(0, 1fr); } }
figure { margin: 0; background: var(--face); border: 1px solid var(--hair); border-radius: 12px; overflow: hidden; position: relative; }
figure.live { border-color: rgba(61,204,128,.45); }
figure .pic { aspect-ratio: 16 / 9; background: var(--well); display: flex; align-items: center; justify-content: center; position: relative; cursor: pointer; }
figure img { width: 100%; height: 100%; object-fit: contain; display: none; }
figure.has img { display: block; }
figure .wait { color: var(--engraved); font-size: 13px; position: absolute; }
figure.has .wait { display: none; }
figure.stale .pic::after { content: "No new picture"; position: absolute; inset: auto 10px 10px auto; padding: 3px 8px;
  border-radius: 6px; background: rgba(0,0,0,.6); color: var(--amber); font-size: 12px; }
figure:fullscreen { background: #000; border: 0; border-radius: 0; display: flex; flex-direction: column; }
figure:fullscreen .pic { aspect-ratio: auto; flex: 1; }
figcaption { padding: 7px 8px 7px 12px; color: var(--dim); font-size: 12.5px; display: flex; flex-wrap: wrap; align-items: center; gap: 6px 8px; min-height: 40px; }
figcaption b { font-weight: 500; color: var(--engraved); letter-spacing: .12em; text-transform: uppercase; font-size: 11px; flex: none; }
figcaption .name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1 1 120px; }
.badge { flex: none; font-size: 11px; font-weight: 600; color: var(--signal); background: rgba(61,204,128,.12); border-radius: 6px; padding: 2px 7px; }
.badge[hidden], .chip[hidden] { display: none; }
.chip { flex: none; display: inline-flex; align-items: center; gap: 5px; height: 26px; padding: 0 9px; border-radius: 13px;
  border: 1px solid var(--hair); background: transparent; color: var(--dim); font-size: 12px; cursor: pointer; }
.chip:hover { color: var(--ink); border-color: rgba(255,255,255,.18); }
.chip svg { width: 13px; height: 13px; }
.chip.on { color: var(--ink); background: var(--raised); }
.empty { color: var(--engraved); padding: 40px 12px; text-align: center; border: 1px dashed var(--hair); border-radius: 12px; }
.now { margin-top: 12px; background: var(--face); border: 1px solid var(--hair); border-radius: 12px; padding: 12px 14px 13px; }
.now[hidden] { display: none; }
.now .where { color: var(--engraved); font-size: 11px; letter-spacing: .12em; text-transform: uppercase; }
.now .text { margin-top: 4px; font-size: 16px; line-height: 1.45; }
.checks { margin-top: 12px; background: var(--face); border: 1px solid var(--hair); border-radius: 12px; padding: 4px 14px; }
.row { display: flex; align-items: center; gap: 10px; min-height: 38px; border-bottom: 1px solid var(--hair); }
.row:last-child { border-bottom: 0; }
.row .label { width: 78px; flex: none; color: var(--engraved); font-size: 11px; letter-spacing: .12em; text-transform: uppercase; }
.row .value { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row .problem { color: var(--dim); font-size: 12px; margin-left: auto; text-align: right; }
.lamp { width: 7px; height: 7px; border-radius: 50%; flex: none; background: var(--engraved); opacity: .5; }
.lamp.ok { background: var(--signal); opacity: 1; }
.lamp.warn { background: var(--amber); opacity: 1; }
.lamp.fail { background: var(--red); opacity: 1; }
@media (max-width: 600px) {
  .row { flex-wrap: wrap; padding: 9px 0; column-gap: 10px; row-gap: 2px; }
  .row .problem { flex-basis: 100%; margin-left: 17px; text-align: left; }
  .row .value { white-space: normal; }
}
footer { margin-top: 14px; color: var(--engraved); font-size: 12px; }
footer.off { color: var(--amber); }
</style>
</head>
<body>
<main>
  <header>
    <div class="state"><span class="dot" id="dot"></span><span id="state">Connecting</span><span class="time" id="time"></span></div>
    <div class="title" id="title"></div>
    <button class="listen" id="listen" type="button" disabled>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 18v-6a9 9 0 0 1 18 0v6"/><path d="M21 19a2 2 0 0 1-2 2h-1v-6h3zM3 19a2 2 0 0 0 2 2h1v-6H3z"/></svg>
      <span id="listenWord">Listen</span>
    </button>
    <div class="meter">Mic <span class="bar"><i id="level"></i></span></div>
    <p class="hint" id="hint" hidden>Listening to the mic, the same sound that goes into the video, about a quarter of a second late. Use headphones: played out loud, it goes back into the mic and into the take.</p>
  </header>
  <div class="grid">
    <div id="main"></div>
    <div class="side" id="side"></div>
  </div>
  <div class="now" id="now" hidden><div class="where" id="where"></div><div class="text" id="line"></div></div>
  <div class="checks" id="checks"></div>
  <footer id="foot">Only people with this link can see this page. Do not share it.</footer>
</main>
<script>
const base = location.pathname.endsWith('/') ? location.pathname : location.pathname + '/';
const tiles = {};
let lastOK = 0, last = null;
let pinned = null;
try { pinned = localStorage.getItem('ava-pin'); } catch (e) {}

const pinIcon = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 17v5"/><path d="M9 3h6l-1 6 4 4v2H6v-2l4-4z"/></svg>';
const fullIcon = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 3H5a2 2 0 0 0-2 2v3M21 8V5a2 2 0 0 0-2-2h-3M3 16v3a2 2 0 0 0 2 2h3M16 21h3a2 2 0 0 0 2-2v-3"/></svg>';

function clock(s) {
  s = Math.max(0, Math.floor(s));
  const m = Math.floor(s / 60), r = s % 60;
  return String(m).padStart(2, '0') + ':' + String(r).padStart(2, '0');
}

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function pin(id) {
  pinned = pinned === id ? null : id;
  try { pinned ? localStorage.setItem('ava-pin', pinned) : localStorage.removeItem('ava-pin'); } catch (e) {}
  if (last) render(last);
}

function tile(stream) {
  let t = tiles[stream.id];
  if (!t) {
    const fig = el('figure');
    const pic = el('div', 'pic');
    pic.tabIndex = 0;
    pic.setAttribute('role', 'button');
    const img = el('img');
    img.alt = stream.label;
    pic.append(img, el('div', 'wait', 'Waiting for the picture'));
    pic.addEventListener('click', () => pin(stream.id));
    pic.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pin(stream.id); } });
    const cap = el('figcaption');
    const kind = el('b', '', stream.kind);
    const name = el('span', 'name', stream.label);
    const badge = el('span', 'badge', 'In the video');
    const pinBtn = el('button', 'chip');
    pinBtn.type = 'button';
    pinBtn.addEventListener('click', () => pin(stream.id));
    const full = el('button', 'chip');
    full.type = 'button';
    full.innerHTML = fullIcon + '<span>Full screen</span>';
    full.title = 'Full screen';
    full.addEventListener('click', () => { if (document.fullscreenElement) document.exitFullscreen(); else if (fig.requestFullscreen) fig.requestFullscreen(); });
    cap.append(kind, name, badge, pinBtn, full);
    fig.append(pic, cap);
    t = tiles[stream.id] = { fig, img, name, badge, pinBtn, full, shown: 0, live: true };
    loop(t, stream.id, stream.id === 'screen' ? 500 : 125);
  }
  t.name.textContent = stream.label;
  return t;
}

async function loop(t, id, every) {
  while (t.live) {
    const t0 = performance.now();
    try {
      const r = await fetch(base + 'frame/' + id + '.jpg', { cache: 'no-store' });
      if (r.status === 200) {
        const url = URL.createObjectURL(await r.blob());
        if (!t.live) { URL.revokeObjectURL(url); break; }
        const old = t.img.dataset.url;
        t.img.src = url;
        t.img.dataset.url = url;
        if (old) setTimeout(() => URL.revokeObjectURL(old), 2000);
        t.shown = Date.now();
        t.fig.classList.add('has');
      }
    } catch (e) {}
    await new Promise(r => setTimeout(r, Math.max(40, every - (performance.now() - t0))));
  }
}

// Listen: the mic as it is recorded, streamed from the Mac and played with a small cushion.
let audio = null;
const listenBtn = document.getElementById('listen');
listenBtn.addEventListener('click', () => audio ? stopListening() : startListening());

function setListening(on) {
  listenBtn.classList.toggle('on', on);
  listenBtn.setAttribute('aria-pressed', on ? 'true' : 'false');
  document.getElementById('listenWord').textContent = on ? 'Stop listening' : 'Listen';
  document.getElementById('hint').hidden = !on;
}

function stopListening() {
  if (!audio) return;
  audio.ctrl.abort();
  audio.ctx.close();
  audio = null;
  setListening(false);
}

async function startListening() {
  const Ctx = window.AudioContext || window.webkitAudioContext;
  if (!Ctx) return;
  const ctx = new Ctx();
  const ctrl = new AbortController();
  const mine = audio = { ctx, ctrl };
  setListening(true);
  await ctx.resume();
  try {
    const r = await fetch(base + 'audio', { cache: 'no-store', signal: ctrl.signal });
    const reader = r.body.getReader();
    let carry = null, at = 0;
    for (;;) {
      const { value, done } = await reader.read();
      if (done || audio !== mine) break;
      let bytes = value;
      if (carry !== null) { const joined = new Uint8Array(bytes.length + 1); joined[0] = carry; joined.set(bytes, 1); bytes = joined; carry = null; }
      if (bytes.length % 2) { carry = bytes[bytes.length - 1]; bytes = bytes.subarray(0, bytes.length - 1); }
      const n = bytes.length / 2;
      if (!n) continue;
      const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.length);
      const buf = ctx.createBuffer(1, n, 24000);
      const ch = buf.getChannelData(0);
      for (let i = 0; i < n; i++) ch[i] = view.getInt16(i * 2, true) / 32768;
      const now = ctx.currentTime;
      // Start a quarter second behind, and catch up after a stall instead of drifting late.
      if (at < now + 0.03 || at > now + 0.8) at = now + 0.25;
      const src = ctx.createBufferSource();
      src.buffer = buf;
      src.connect(ctx.destination);
      src.start(at);
      at += buf.duration;
    }
  } catch (e) {}
  if (audio === mine) stopListening();
}

const words = {
  ready: 'Ready', starting: 'Starting', recording: 'Recording', stopping: 'Stopping',
  finishing: 'Finishing', done: 'Saved', failed: 'Stopped'
};

function render(s) {
  last = s;
  document.getElementById('state').textContent = words[s.phase] || s.phase;
  const dot = document.getElementById('dot');
  dot.className = 'dot ' + (s.phase === 'recording' ? 'rec' : s.phase === 'failed' ? 'warn' : s.phase === 'ready' || s.phase === 'done' ? 'ok' : '');
  document.getElementById('time').textContent = s.phase === 'recording' ? clock(s.elapsed) : '';
  document.getElementById('title').textContent = s.message ? s.title + '  ·  ' + s.message : s.title;
  const level = Math.min(1, Math.max(0, (s.level + 60) / 60));
  const bar = document.getElementById('level');
  bar.style.width = (level * 100).toFixed(1) + '%';
  bar.className = s.level > -6 ? 'hot' : '';
  listenBtn.disabled = !s.listen && !audio;

  const main = document.getElementById('main'), side = document.getElementById('side');
  const ids = new Set(s.streams.map(x => x.id));
  for (const id of Object.keys(tiles)) {
    if (!ids.has(id)) {
      tiles[id].live = false;
      tiles[id].fig.remove();
      if (tiles[id].img.dataset.url) URL.revokeObjectURL(tiles[id].img.dataset.url);
      delete tiles[id];
    }
  }
  // The pinned picture is the big one. Without a pin, the one in the video, following Me and
  // Screen as they switch, like a meeting app following whoever speaks.
  const first = s.streams.find(x => x.id === pinned) || s.streams.find(x => x.id === s.showing) || s.streams[0];
  s.streams.forEach(stream => {
    const t = tile(stream);
    const big = stream === first;
    const parent = big ? main : side;
    if (t.fig.parentNode !== parent || (big && main.firstChild !== t.fig)) parent.append(t.fig);
    const isPinned = stream.id === pinned;
    t.pinBtn.innerHTML = pinIcon + '<span>' + (isPinned ? 'Unpin' : 'Pin') + '</span>';
    t.pinBtn.classList.toggle('on', isPinned);
    t.pinBtn.title = isPinned ? 'Unpin' : 'Pin this one big';
    t.pinBtn.hidden = s.streams.length < 2;
    t.full.hidden = !big;
    const inVideo = s.showing && (stream.id === s.showing);
    t.badge.hidden = !inVideo;
    t.fig.classList.toggle('live', !!inVideo);
  });
  if (!s.streams.length && !main.firstChild) main.append(el('div', 'empty', 'No camera yet'));
  if (s.streams.length) main.querySelectorAll('.empty').forEach(e => e.remove());
  // A still screen sends no new frames, so only a camera can look stuck.
  for (const [id, t] of Object.entries(tiles)) t.fig.classList.toggle('stale', id !== 'screen' && t.shown > 0 && Date.now() - t.shown > 3000);

  const now = document.getElementById('now');
  now.hidden = !s.line;
  if (s.line) {
    document.getElementById('where').textContent = 'Reading now · ' + s.line.section + ' · ' + s.line.number + ' of ' + s.line.total;
    document.getElementById('line').textContent = s.line.text;
  }

  const box = document.getElementById('checks');
  box.replaceChildren(...s.checks.map(c => {
    const row = el('div', 'row');
    row.append(el('span', 'lamp ' + c.state), el('span', 'label', c.label), el('span', 'value', c.value));
    if (c.problem) row.append(el('span', 'problem', c.problem));
    return row;
  }));
}

async function poll() {
  try {
    const r = await fetch(base + 'status', { cache: 'no-store' });
    if (!r.ok) throw new Error(String(r.status));
    render(await r.json());
    lastOK = Date.now();
    const foot = document.getElementById('foot');
    foot.className = '';
    foot.textContent = 'Only people with this link can see this page. Do not share it.';
  } catch (e) {
    if (Date.now() - lastOK > 4000) {
      const foot = document.getElementById('foot');
      foot.className = 'off';
      foot.textContent = 'Cannot reach the Mac. Trying again.';
      document.getElementById('state').textContent = 'Not connected';
      document.getElementById('dot').className = 'dot warn';
    }
  }
  setTimeout(poll, 1000);
}
poll();
</script>
</body>
</html>
"""#
}
