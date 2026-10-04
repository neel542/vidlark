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

// MARK: - Server

/// A tiny web server on port 8790. Every address starts with the secret; anything else is "not found".
final class LiveServer: @unchecked Sendable {
    static let port: UInt16 = 8790
    private let frames: LiveFrames
    private let queue = DispatchQueue(label: "ava.live.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var secret: String
    /// Builds the status JSON. Called on the main thread.
    var status: (() -> Data)?
    /// Why the server stopped, for example the port is taken. Called on the server queue.
    var onFailure: ((String) -> Void)?

    init(frames: LiveFrames, token: String) {
        self.frames = frames
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
  --body: #0E1110; --face: #151917; --well: #070908; --hair: rgba(255,255,255,.075);
  --ink: #ECF1EE; --dim: #A3ADA8; --engraved: #86918B;
  --signal: #3DCC80; --amber: #E8B34B; --red: #F04E3E;
}
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--body); color: var(--ink);
  font: 14px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif; }
main { max-width: 1400px; margin: 0 auto; padding: 20px 16px 32px; }
header { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; margin-bottom: 16px; }
.state { display: flex; align-items: center; gap: 10px; font-size: 20px; font-weight: 500; }
.dot { width: 11px; height: 11px; border-radius: 50%; background: var(--engraved); flex: none; }
.dot.rec { background: var(--red); animation: pulse 1.4s ease-in-out infinite; }
.dot.ok { background: var(--signal); }
.dot.warn { background: var(--amber); }
@keyframes pulse { 50% { opacity: .35; } }
.time { font-variant-numeric: tabular-nums; color: var(--ink); }
.title { color: var(--dim); font-size: 14px; flex: 1 1 200px; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.meter { display: flex; align-items: center; gap: 8px; color: var(--engraved); font-size: 11px; letter-spacing: .12em; text-transform: uppercase; }
.bar { width: 140px; height: 6px; border-radius: 3px; background: var(--well); overflow: hidden; }
.bar i { display: block; height: 100%; width: 0; background: var(--signal); transition: width .2s linear; }
.bar i.hot { background: var(--amber); }
.grid { display: grid; grid-template-columns: minmax(0, 2fr) minmax(0, 1fr); gap: 12px; align-items: start; }
.side { display: grid; gap: 12px; }
.grid:has(.side:empty) { grid-template-columns: minmax(0, 1fr); max-width: 980px; }
@media (max-width: 800px) { .grid { grid-template-columns: 1fr; } }
figure { margin: 0; background: var(--face); border: 1px solid var(--hair); border-radius: 12px; overflow: hidden; position: relative; }
figure .pic { aspect-ratio: 16 / 9; background: var(--well); display: flex; align-items: center; justify-content: center; position: relative; }
figure img { width: 100%; height: 100%; object-fit: contain; display: none; }
figure.has img { display: block; }
figure .wait { color: var(--engraved); font-size: 13px; position: absolute; }
figure.has .wait { display: none; }
figure.stale .pic::after { content: "No new picture"; position: absolute; inset: auto 10px 10px auto; padding: 3px 8px;
  border-radius: 6px; background: rgba(0,0,0,.6); color: var(--amber); font-size: 12px; }
figcaption { padding: 8px 12px; color: var(--dim); font-size: 12.5px; display: flex; justify-content: space-between; gap: 8px; }
figcaption b { font-weight: 500; color: var(--engraved); letter-spacing: .12em; text-transform: uppercase; font-size: 11px; }
.empty { color: var(--engraved); padding: 40px 12px; text-align: center; border: 1px dashed var(--hair); border-radius: 12px; }
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
footer { margin-top: 14px; color: var(--engraved); font-size: 12px; }
footer.off { color: var(--amber); }
</style>
</head>
<body>
<main>
  <header>
    <div class="state"><span class="dot" id="dot"></span><span id="state">Connecting</span><span class="time" id="time"></span></div>
    <div class="title" id="title"></div>
    <div class="meter">Mic <span class="bar"><i id="level"></i></span></div>
  </header>
  <div class="grid">
    <div id="main"></div>
    <div class="side" id="side"></div>
  </div>
  <div class="checks" id="checks"></div>
  <footer id="foot">Only people with this link can see this page. Do not share it.</footer>
</main>
<script>
const base = location.pathname.endsWith('/') ? location.pathname : location.pathname + '/';
const tiles = {};
let lastOK = 0;

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

function tile(stream, parent) {
  let t = tiles[stream.id];
  if (!t) {
    const fig = el('figure');
    const pic = el('div', 'pic');
    const img = el('img');
    img.alt = stream.label;
    pic.append(img, el('div', 'wait', 'Waiting for the picture'));
    const cap = el('figcaption');
    const kind = el('b', '', stream.kind);
    const name = el('span', '', stream.label);
    cap.append(kind, name);
    fig.append(pic, cap);
    t = tiles[stream.id] = { fig, img, name, shown: 0, live: true };
    loop(t, stream.id, stream.id === 'screen' ? 500 : 125);
  }
  t.name.textContent = stream.label;
  if (t.fig.parentNode !== parent) parent.append(t.fig);
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

const words = {
  ready: 'Ready', starting: 'Starting', recording: 'Recording', stopping: 'Stopping',
  finishing: 'Finishing', done: 'Saved', failed: 'Stopped'
};

function render(s) {
  document.getElementById('state').textContent = words[s.phase] || s.phase;
  const dot = document.getElementById('dot');
  dot.className = 'dot ' + (s.phase === 'recording' ? 'rec' : s.phase === 'failed' ? 'warn' : s.phase === 'ready' || s.phase === 'done' ? 'ok' : '');
  document.getElementById('time').textContent = s.phase === 'recording' ? clock(s.elapsed) : '';
  document.getElementById('title').textContent = s.message ? s.title + '  ·  ' + s.message : s.title;
  const level = Math.min(1, Math.max(0, (s.level + 60) / 60));
  const bar = document.getElementById('level');
  bar.style.width = (level * 100).toFixed(1) + '%';
  bar.className = s.level > -6 ? 'hot' : '';

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
  s.streams.forEach((stream, i) => tile(stream, i === 0 ? main : side));
  if (!s.streams.length && !main.firstChild) main.append(el('div', 'empty', 'No camera yet'));
  if (s.streams.length) main.querySelectorAll('.empty').forEach(e => e.remove());
  // A still screen sends no new frames, so only a camera can look stuck.
  for (const [id, t] of Object.entries(tiles)) t.fig.classList.toggle('stale', id !== 'screen' && t.shown > 0 && Date.now() - t.shown > 3000);

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
