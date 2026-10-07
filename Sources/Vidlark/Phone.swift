import AppKit
import AVFoundation
import CoreImage
import Network
import Security
import SystemConfiguration
import VideoToolbox

// Phones over Wi-Fi. Continuity Camera needs the iPhone and the Mac on one Apple Account; this
// needs nothing but the same Wi-Fi, and works with an Android phone too. Vidlark serves a small page
// over a secure connection, each phone opens it from its own QR code, and its browser sends the
// camera here already compressed (H.264, made by the phone's own encoder through WebCodecs).
// The camera file keeps those pictures exactly as they came, so nothing is compressed twice; a
// decoded copy feeds the previews, the face framing and the live page, only while one shows it.
// The sound is the Mac's mic, as with any other camera. Up to four phones film at once, each its
// own camera file, so one take has several angles to pick from in editing. A phone can also be a
// microphone: its page sends its sound as plain 16-bit samples, which Vidlark records as a file of its
// own. Its mute is one switch shared by the phone and the Mac: either can flip it, the last flip
// wins, both show it, and while it is on the phone's mic is off altogether.
//
// A phone filming another angle stands by between takes: it keeps its picture on its own screen,
// so it can be framed, but sends nothing until a take starts or the Mac shows its picture. That
// saves the phone's battery and the Mac's work.
//
// Browsers only let a page use the camera over a secure connection, so Vidlark makes its own
// certificate the first time. It is not signed by anyone the phone knows, which is why the browser
// asks once ("This Connection Is Not Private"): the link only works on this Wi-Fi and carries a secret.

/// How one phone is doing, for the panel.
struct PhoneState: Equatable {
    var serving = false
    /// The phone's page has been in touch in the last 3 seconds, sending pictures or resting.
    var present = false
    /// A picture arrived in the last 2 seconds.
    var connected = false
    var width = 0
    var height = 0
    var fps = 0
    var failure: String?

    /// The phone's page has its camera running.
    var camera = false
    /// The phone's microphone, as its page says.
    var mic: PhoneMic = .off
    /// In touch with its camera ready, sending no pictures until a take or a preview needs them.
    var standby = false
    /// The phone's mic is muted, from the phone or from this Mac, whichever flipped it last.
    var muted = false
    /// The last flip came from the phone itself.
    var mutedOnPhone = false

    /// A tall picture (9:16), chosen on the phone.
    var tall: Bool { height > width }
}

/// A phone's microphone, as its page reports it.
enum PhoneMic: String {
    /// Not in use: Vidlark has not asked for it.
    case off
    /// Sending its sound to Vidlark.
    case on
    /// Asking the person holding it to allow the mic.
    case asking
    /// Muted on the phone: its mic stays off whatever Vidlark asks.
    case muted
    /// The phone did not allow its microphone.
    case denied
}

/// The phone link: one secure page on the Wi-Fi that up to four phones open at once, each from its
/// own code (Phone 1, Phone 2 and so on). Each phone is a camera of its own, so one take can film
/// several angles; every phone does its own compressing, so each one adds very little for the Mac.
final class PhoneLink: @unchecked Sendable {
    static let shared = PhoneLink()
    /// How many phones can film at once.
    static let most = 4
    static let name = "Phone over Wi-Fi"
    static let port: UInt16 = 8791

    /// The camera ID the app stores for phone n. Phone 1 keeps the ID it had before there could be more.
    static func cameraID(_ number: Int) -> String { number == 1 ? "vidlark.iphone.wifi" : "vidlark.phone.\(number)" }

    /// Which phone a stored camera ID is, or nil for any other camera.
    static func number(of id: String?) -> Int? {
        guard let id else { return nil }
        return (1...most).first { cameraID($0) == id }
    }

    static func name(_ number: Int) -> String { "Phone \(number)" }

    /// The mic ID the app stores for phone n's microphone.
    static func micID(_ number: Int) -> String { "vidlark.phone.\(number).mic" }

    /// Which phone a stored mic ID is, or nil for any other mic.
    static func number(ofMic id: String?) -> Int? {
        guard let id else { return nil }
        return (1...most).first { micID($0) == id }
    }

    fileprivate let queue = DispatchQueue(label: "vidlark.phone")
    private let lock = NSLock()
    private var listener: NWListener?
    private var secret: String
    private var failure: String?
    private(set) var cameras: [PhoneCamera] = []
    /// Called on the link's queue when a phone's mic or mute changes, so the panel shows it at once
    /// instead of at its next look.
    var onChange: ((Int) -> Void)?

    fileprivate func changed(_ number: Int) { onChange?(number) }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "phoneToken"), !saved.isEmpty {
            secret = saved
        } else {
            secret = LiveServer.newToken()
            UserDefaults.standard.set(secret, forKey: "phoneToken")
        }
        cameras = (1...Self.most).map { PhoneCamera(number: $0, link: self) }
    }

    func camera(_ number: Int) -> PhoneCamera { cameras[min(max(number, 1), Self.most) - 1] }

    /// The link phone n's code holds: this Mac's address on the Wi-Fi. Many Android phones cannot
    /// find a Mac by its .local name, so the number it is reached at now goes in; the code is made
    /// again each time it shows. With no address, the .local name.
    func link(_ number: Int) -> String? {
        let host = Self.wifiAddress() ?? (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
        guard let host else { return nil }
        return "https://\(host):\(Self.port)/\(lock.withLock { secret })/\(number)/"
    }

    /// The IPv4 address of the network the Mac uses now (Wi-Fi, or a cable).
    static func wifiAddress() -> String? {
        let key = "State:/Network/Global/IPv4" as CFString
        guard let global = SCDynamicStoreCopyValue(nil, key) as? [String: Any],
              let primary = global["PrimaryInterface"] as? String else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard String(cString: item.ifa_name) == primary, let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    func state(_ number: Int) -> PhoneState {
        let phone = self.camera(number)
        var state = queue.sync { phone.heard() }
        lock.withLock {
            state.serving = listener != nil
            state.failure = failure
        }
        return state
    }

    // MARK: Server

    func start() {
        guard lock.withLock({ listener == nil }) else { return }
        do {
            let identity = try Self.identity()
            let tls = NWProtocolTLS.Options()
            guard let secIdentity = sec_identity_create(identity) else { throw RecorderError("The certificate could not be read.") }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            let parameters = NWParameters(tls: tls)
            parameters.allowLocalEndpointReuse = true
            let l = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed(let error) = state {
                    self.lock.withLock { self.listener = nil; self.failure = "The phone link stopped: \(error.localizedDescription)" }
                }
            }
            l.start(queue: queue)
            lock.withLock { listener = l; failure = nil }
        } catch {
            lock.withLock { failure = "The phone link could not start: \(error.localizedDescription)" }
        }
    }

    func stop() {
        lock.withLock { listener?.cancel(); listener = nil }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
    }

    /// Reads requests one after another on the same connection, so each phone keeps one secure
    /// connection open instead of a new one for every batch of pictures.
    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            while let request = Self.request(from: &buffer) {
                self.answer(connection, request)
            }
            if done || error != nil || buffer.count > 16 << 20 {
                connection.cancel()
            } else {
                self.receive(connection, buffer)
            }
        }
    }

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    /// Takes one whole request off the front of the buffer, or nil while it is still arriving.
    private static func request(from buffer: inout Data) -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let words = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)])
        buffer = Data(buffer[buffer.index(bodyStart, offsetBy: length)...])
        guard words.count >= 2 else { return Request(method: "", path: "", headers: headers, body: body) }
        return Request(method: String(words[0]), path: String(words[1]), headers: headers, body: body)
    }

    /// `/<secret>/<n>/` is phone n's page and `/<secret>/<n>/send` where it posts. Without a number
    /// it is phone 1, the link from before there could be more than one.
    private func answer(_ connection: NWConnection, _ request: Request) {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        var parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first, Self.same(first, lock.withLock { secret }) else {
            return send(connection, 404, "text/plain", Data("Not found".utf8))
        }
        parts.removeFirst()
        var number = 1
        if let n = parts.first.flatMap(Int.init) {
            guard (1...Self.most).contains(n) else { return send(connection, 404, "text/plain", Data("Not found".utf8)) }
            number = n
            parts.removeFirst()
        }
        let phone = self.camera(number)
        switch (request.method, parts.joined(separator: "/")) {
        case ("GET", ""):
            let role = phone.role
            return send(connection, 200, "text/html; charset=utf-8", Data(PhonePage.page(camera: role.camera, mic: role.mic).utf8))
        case ("GET", "mic.js"):
            return send(connection, 200, "text/javascript; charset=utf-8", Data(PhonePage.micWorklet.utf8))
        case ("POST", "send"):
            let reply = phone.take(request.body, from: request.headers["x-session"] ?? "", headers: request.headers)
            send(connection, 200, "application/json", Data(reply.utf8))
        default:
            send(connection, 404, "text/plain", Data("Not found".utf8))
        }
    }

    private func send(_ connection: NWConnection, _ code: Int, _ type: String, _ body: Data) {
        let reason = [200: "OK", 404: "Not Found"][code] ?? "OK"
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Robots-Tag: noindex\r\n"
            + "X-Content-Type-Options: nosniff\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { error in
            if error != nil { connection.cancel() }
        })
    }

    /// Compares every character, so timing does not give the secret away.
    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: Certificate

    /// Vidlark's own certificate, made the first time with the Mac's built-in openssl and kept in
    /// Application Support. It is read into memory only, never into the keychain.
    private static func identity() throws -> SecIdentity {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vidlark/iPhone link", isDirectory: true)
        let p12 = folder.appendingPathComponent("identity.p12")
        if !FileManager.default.fileExists(atPath: p12.path) {
            try make(p12, in: folder)
        }
        let data = try Data(contentsOf: p12)
        var items: CFArray?
        let options: [CFString: Any] = [kSecImportExportPassphrase: "vidlark", kSecImportToMemoryOnly: true]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[CFString: Any]])?.first,
              let identity = first[kSecImportItemIdentity] else {
            throw RecorderError("The certificate could not be read (\(status)).")
        }
        return identity as! SecIdentity
    }

    private static func make(_ p12: URL, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = folder.appendingPathComponent("key.pem"), cert = folder.appendingPathComponent("cert.pem")
        let host = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "DNS:\($0).local," } ?? ""
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw RecorderError("openssl \(arguments.first ?? "") failed.") }
        }
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", cert.path, "-days", "3650",
                 "-subj", "/CN=Vidlark", "-addext", "subjectAltName=\(host)DNS:localhost"])
        try run(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path, "-passout", "pass:vidlark"])
        try? FileManager.default.removeItem(at: key)
    }

    // MARK: QR code

    /// The link as a QR code, black on white, for the iPhone's Camera app.
    static func qrCode(_ text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }
        let scale = (side / code.extent.width).rounded(.down)
        let image = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: image)
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }
}

/// One phone on the link: whichever phone opened code n last. It goes to one recorder at a time,
/// the main camera's or another camera's.
final class PhoneCamera: @unchecked Sendable {
    let number: Int
    private unowned let link: PhoneLink
    var cameraID: String { PhoneLink.cameraID(number) }
    var name: String { PhoneLink.name(number) }

    // The link's queue only.
    private var format: CMVideoFormatDescription?
    private var formatBytes = Data()
    private var decoder: VTDecompressionSession?
    private var session = ""
    private var lastPicture: CFTimeInterval = 0
    private var lastHeard: CFTimeInterval = 0
    private var arrivals: [CFTimeInterval] = []
    /// What the page says it has running, its mic, and the shape picked on it.
    private var pageCamera = false
    private var pageMic = PhoneMic.off
    private var pageTall: Bool?
    /// Sound: the sample count and Mac time of the first batch, so every later batch is timed by
    /// its place in the phone's own stream, and the format for the current sample rate.
    private var soundAnchor: (index: Double, mac: Double)?
    private var soundFormat: (rate: Double, description: CMAudioFormatDescription)?

    // Under the lock.
    private let lock = NSLock()
    private var size = (width: 0, height: 0)
    private var keyWanted = false
    private var resting = false
    private var recording = false
    /// The pictures are decoded only while something on screen shows them (a preview, the face
    /// framing, the live page). The camera file never needs it: it keeps them as they came.
    private var decoding = false
    private var owner: ObjectIdentifier?
    private var compressed: ((CMSampleBuffer) -> Void)?
    private var decoded: ((CMSampleBuffer) -> Void)?
    private var sized: ((Int, Int) -> Void)?
    /// A take is starting or running, so the pictures are needed whether or not anything shows them.
    private var taking = false
    /// The phone's code window is open: it keeps sending, so the window can say it works.
    private var onScreen = false
    /// Where the phone's sound goes, while it is used as a microphone.
    private var soundOwner: ObjectIdentifier?
    private var sound: ((CMSampleBuffer) -> Void)?

    fileprivate init(number: Int, link: PhoneLink) {
        self.number = number
        self.link = link
    }

    /// Starts the link, if it is not running yet.
    func start() { link.start() }

    var state: PhoneState { link.state(number) }

    /// The link's queue only. What has been heard from this phone lately.
    fileprivate func heard() -> PhoneState {
        let now = CACurrentMediaTime()
        let recent = arrivals.filter { now - $0 < 2 }
        let (size, sending, camera) = lock.withLock { (self.size, wantsPictures, owner != nil) }
        let present = now - lastHeard < 3
        var state = PhoneState(present: present, connected: now - lastPicture < 2,
                               width: size.width, height: size.height, fps: recent.count / 2)
        // Standing by, the page has sent no format yet: its shape is still known.
        if state.width == 0, let tall = pageTall { (state.width, state.height) = tall ? (1080, 1920) : (1920, 1080) }
        state.camera = present && pageCamera
        state.mic = present ? pageMic : .off
        state.standby = state.camera && camera && !sending
        (state.muted, state.mutedOnPhone) = lock.withLock { (muted, mutedOnPhone) }
        return state
    }

    /// What the page should be when it opens: a camera, a microphone, or both.
    var role: (camera: Bool, mic: Bool) {
        lock.withLock { (owner != nil || soundOwner == nil, soundOwner != nil) }
    }

    /// Under the lock. The phone's mic, muted from the phone or the Mac.
    private var muted = false
    private var mutedOnPhone = false

    /// Under the lock. Pictures are wanted while something shows them, a take needs them, or the
    /// code window is open; otherwise a phone filming an angle stands by.
    private var wantsPictures: Bool { owner != nil && (decoding || taking || onScreen || keyWanted) }

    /// Where the pictures go: compressed ones for the camera file, decoded ones for everything on
    /// screen, and the picture size whenever it changes. One recorder at a time; the newest wins.
    func deliver(to owner: AnyObject, compressed: @escaping (CMSampleBuffer) -> Void, decoded: @escaping (CMSampleBuffer) -> Void,
                 sized: @escaping (Int, Int) -> Void) {
        lock.withLock {
            self.owner = ObjectIdentifier(owner)
            self.compressed = compressed
            self.decoded = decoded
            self.sized = sized
            decoding = false
        }
    }

    /// That recorder no longer wants the pictures. A recorder that has since taken over keeps them.
    func stopDelivering(to owner: AnyObject) {
        lock.withLock {
            guard self.owner == ObjectIdentifier(owner) else { return }
            self.owner = nil
            compressed = nil
            decoded = nil
            sized = nil
            decoding = false
        }
    }

    /// Whether anything on screen shows this phone now. Decoding starts on a whole picture, which
    /// the phone is asked for at once.
    func decode(_ on: Bool, for owner: AnyObject) {
        lock.withLock {
            guard self.owner == ObjectIdentifier(owner), decoding != on else { return }
            decoding = on
            if on { keyWanted = true }
        }
    }

    /// Asks the phone for a whole picture next, so a file can start on it.
    func askForKeyPicture() { lock.withLock { keyWanted = true } }

    /// While resting, the phone stops sending, which saves its battery and the Mac's work.
    func rest(_ on: Bool) { lock.withLock { resting = on } }

    /// Shown on the phone, so whoever holds it knows the take is rolling. It also keeps the phone's
    /// picture shape from changing mid-take.
    func setRecording(_ on: Bool) { lock.withLock { recording = on } }

    /// From the 3, 2, 1 until the take's file closes: the phone sends its pictures, standing by or not.
    func setTaking(_ on: Bool) {
        lock.withLock {
            if on && !taking { keyWanted = true }
            taking = on
        }
    }

    /// Whether this phone's code window is open.
    func setOnScreen(_ on: Bool) { lock.withLock { onScreen = on } }

    /// Mutes or unmutes the phone's mic from this Mac. The phone follows on its next batch.
    func setMuted(_ on: Bool) {
        lock.withLock {
            guard muted != on else { return }
            muted = on
            mutedOnPhone = false
        }
        link.changed(number)
    }

    /// Where the phone's sound goes, with the mic on: a mic recorder, which also shows its level.
    /// The newest owner wins; nil from the owner turns the phone's mic off again.
    func listen(_ owner: AnyObject, _ taker: ((CMSampleBuffer) -> Void)?) {
        lock.withLock {
            if let taker {
                soundOwner = ObjectIdentifier(owner)
                sound = taker
            } else if soundOwner == ObjectIdentifier(owner) {
                soundOwner = nil
                sound = nil
            }
        }
    }

    /// The link's queue only. One batch from the phone, then the reply, which carries the Mac's
    /// clock so the phone can time its pictures on it. Each record is a kind byte, then for a format
    /// (1) the width and height (2 bytes each) and the H.264 settings (avcC, 4 byte length first),
    /// or for a picture (2) a whole-picture flag, the Mac time it was taken in milliseconds (8 byte
    /// float) and the picture (4 byte length first). Little endian throughout.
    fileprivate func take(_ body: Data, from sender: String, headers: [String: String] = [:]) -> String {
        // The newest page wins: another phone scanning the same code, or the same one reloaded,
        // takes over when it says hello (an empty batch), and the one before it is told to stop.
        let adopted = sender != session && body.isEmpty && !sender.isEmpty
        if adopted {
            session = sender
            format = nil
            formatBytes = Data()
            soundAnchor = nil
        }
        if sender == session {
            // Pages from before these headers say nothing: they are cameras that always send.
            if let has = headers["x-has"] {
                let parts = has.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                pageCamera = parts.contains("camera")
            } else {
                pageCamera = true
            }
            let mic = headers["x-mic"].flatMap(PhoneMic.init) ?? .off
            let micChanged = mic != pageMic
            pageMic = mic
            if let shape = headers["x-shape"] { pageTall = shape == "tall" }
            // The mute switch: a flip on the phone is sent until the reply shows it. A page that has
            // just taken over brings what it last knew, so a phone that was muted stays muted after
            // a reload or a restart of the app. Otherwise the last flip, here or there, stands.
            let flip = headers["x-mute-set"].map { $0 == "1" } ?? (adopted ? headers["x-muted"].map { $0 == "1" } : nil)
            let muteChanged = flip.map { on in
                lock.withLock { () -> Bool in
                    guard muted != on else { return false }
                    muted = on
                    mutedOnPhone = true
                    return true
                }
            } ?? false
            read(body)
            if micChanged || muteChanged { link.changed(number) }
        }
        // "sound": Vidlark records this phone's sound; "mic": the phone's mic should be on right now.
        let reply = lock.withLock { () -> (key: Bool, resting: Bool, recording: Bool, send: Bool, camera: Bool, sound: Bool, muted: Bool, byPhone: Bool) in
            defer { keyWanted = false }
            return (keyWanted, resting, recording, wantsPictures, owner != nil || soundOwner == nil, soundOwner != nil, muted, mutedOnPhone)
        }
        return "{\"mac\":\(CACurrentMediaTime() * 1000),\"key\":\(reply.key),\"rest\":\(reply.resting),\"recording\":\(reply.recording),"
            + "\"send\":\(reply.send),\"camera\":\(reply.camera),\"sound\":\(reply.sound),"
            + "\"mic\":\(reply.sound && !reply.resting && !reply.muted),\"muted\":\(reply.muted),\"mutedBy\":\"\(reply.byPhone ? "phone" : "mac")\","
            + "\"replaced\":\(sender != session),\"phone\":\(number)}"
    }

    private func read(_ body: Data) {
        lastHeard = CACurrentMediaTime()
        let bytes = [UInt8](body)
        var i = 0
        func u16() -> Int? { guard i + 2 <= bytes.count else { return nil }; defer { i += 2 }; return Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32() -> Int? {
            guard i + 4 <= bytes.count else { return nil }
            defer { i += 4 }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        }
        func f64() -> Double? {
            guard i + 8 <= bytes.count else { return nil }
            defer { i += 8 }
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(bytes[i + k]) << (8 * UInt64(k)) }
            return Double(bitPattern: bits)
        }
        while i < bytes.count {
            let kind = bytes[i]; i += 1
            if kind == 1 {
                guard let w = u16(), let h = u16(), let n = u32(), i + n <= bytes.count else { return }
                useFormat(width: w, height: h, avcC: Data(bytes[i..<i + n]))
                i += n
            } else if kind == 2 {
                guard i < bytes.count else { return }
                let key = bytes[i] != 0; i += 1
                guard let ms = f64(), let n = u32(), i + n <= bytes.count else { return }
                picture(Data(bytes[i..<i + n]), key: key, at: ms / 1000)
                i += n
            } else if kind == 3 {
                // Sound (3): the sample rate (4 bytes), the place of the first sample in the phone's
                // stream and the Mac time it was heard in milliseconds (8 byte floats), then the
                // number of samples (4 bytes) and the samples, 16-bit mono.
                guard let rate = u32(), let index = f64(), let ms = f64(), let n = u32(), i + n * 2 <= bytes.count else { return }
                heardSound(bytes, from: i, count: n, rate: Double(rate), index: index, at: ms / 1000)
                i += n * 2
            } else {
                return
            }
        }
    }

    private func useFormat(width: Int, height: Int, avcC: Data) {
        guard avcC != formatBytes else { return }
        let extensions: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["avcC": avcC]]
        var made: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
                                             width: Int32(width), height: Int32(height), extensions: extensions as CFDictionary,
                                             formatDescriptionOut: &made) == noErr, let made else { return }
        format = made
        formatBytes = avcC
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil
        let changed = lock.withLock { () -> ((Int, Int) -> Void)? in
            defer { size = (width, height) }
            return size != (width, height) ? sized : nil
        }
        changed?(width, height)
    }

    /// The link's queue only. A decoder for the current format, made when first needed.
    private func makeDecoder() -> VTDecompressionSession? {
        if let decoder { return decoder }
        guard let format else { return nil }
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr else { return nil }
        decoder = session
        return session
    }

    /// The link's queue only. One batch of the phone's sound, timed by its place in the phone's own
    /// stream from the first batch on, so the samples run on without a gap or an overlap.
    private func heardSound(_ bytes: [UInt8], from start: Int, count: Int, rate: Double, index: Double, at seconds: Double) {
        guard count > 0, rate >= 8000, rate <= 192_000 else { return }
        guard let taker = lock.withLock({ sound }) else { soundAnchor = nil; return }
        if soundFormat?.rate != rate {
            var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                   mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                                   mBitsPerChannel: 16, mReserved: 0)
            var made: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                 magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &made) == noErr,
                  let made else { return }
            soundFormat = (rate, made)
            soundAnchor = nil
        }
        guard let description = soundFormat?.description else { return }
        // A new stream (the page restarted its mic), or one that went back: time it afresh.
        if let anchor = soundAnchor, index < anchor.index || abs((anchor.mac + (index - anchor.index) / rate) - seconds) > 2 {
            soundAnchor = nil
        }
        let anchor = soundAnchor ?? (index, seconds)
        soundAnchor = anchor
        let time = anchor.mac + (index - anchor.index) / rate

        var block: CMBlockBuffer?
        let length = count * 2
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        _ = bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + start, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: count,
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: CMTimeScale(rate)), packetDescriptions: nil,
            sampleBufferOut: &sample) == noErr, let sample else { return }
        taker(sample)
    }

    private func picture(_ data: Data, key: Bool, at seconds: Double) {
        guard let format else { return }
        let now = CACurrentMediaTime()
        lastPicture = now
        arrivals.append(now)
        if arrivals.count > 90 { arrivals.removeFirst(arrivals.count - 90) }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var length = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &length, sampleBufferOut: &sample) == noErr, let sample else { return }
        if !key, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let (compressed, decoded) = lock.withLock { (self.compressed, decoding ? self.decoded : nil) }
        compressed?(sample)
        guard let decoded else {
            // Nothing shows it: the decoder goes, and comes back on the next whole picture.
            if let decoder { VTDecompressionSessionInvalidate(decoder); self.decoder = nil }
            return
        }
        // A decoder starting cold needs a whole picture first.
        guard decoder != nil || key, let decoder = makeDecoder() else { return }
        VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else { return }
            // Timed on arrival: the previews show each picture as it comes.
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &description)
            guard let description else { return }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
            var frame: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: description,
                                                     sampleTiming: &timing, sampleBufferOut: &frame)
            if let frame { decoded(frame) }
        }
    }
}
