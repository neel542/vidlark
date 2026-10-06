import AppKit
import AVFoundation
import CoreImage
import Network
import Security
import SystemConfiguration
import VideoToolbox

// The iPhone over Wi-Fi. Continuity Camera needs the iPhone and the Mac on one Apple Account; this
// needs nothing but the same Wi-Fi. AVA serves a small page over a secure connection, the iPhone
// opens it from a QR code, and Safari sends its back camera here already compressed (H.264, made by
// the iPhone's own encoder through WebCodecs). camera.mov keeps those pictures exactly as they came,
// so nothing is compressed twice; a decoded copy feeds the previews, the face framing and the live
// page. The sound is the Mac's mic, as with any other camera.
//
// Safari only lets a page use the camera over a secure connection, so AVA makes its own certificate
// the first time. It is not signed by anyone the iPhone knows, which is why Safari asks once
// ("This Connection Is Not Private"): the link only works on this Wi-Fi and carries a secret.

/// How the iPhone is doing, for the panel.
struct PhoneState: Equatable {
    var serving = false
    /// The iPhone page has been in touch in the last 3 seconds, sending pictures or resting.
    var present = false
    /// A picture arrived in the last 2 seconds.
    var connected = false
    var width = 0
    var height = 0
    var fps = 0
    var failure: String?
}

final class PhoneLink: @unchecked Sendable {
    static let shared = PhoneLink()
    /// The camera ID the app stores when the iPhone over Wi-Fi is the camera.
    static let cameraID = "ava.iphone.wifi"
    static let name = "Phone over Wi-Fi"
    static let port: UInt16 = 8791

    private let queue = DispatchQueue(label: "ava.phone")
    private let lock = NSLock()
    private var listener: NWListener?
    private var secret: String
    private var failure: String?

    // Phone queue only.
    private var format: CMVideoFormatDescription?
    private var formatBytes = Data()
    private var decoder: VTDecompressionSession?
    private var session = ""
    private var lastPicture: CFTimeInterval = 0
    private var lastHeard: CFTimeInterval = 0
    private var arrivals: [CFTimeInterval] = []

    // Under the lock.
    private var size = (width: 0, height: 0)
    private var keyWanted = false
    private var resting = false
    private var recording = false
    /// The recorder the pictures go to: the main camera's, or another camera's.
    private var owner: ObjectIdentifier?
    private var compressed: ((CMSampleBuffer) -> Void)?
    private var decoded: ((CMSampleBuffer) -> Void)?
    private var sized: ((Int, Int) -> Void)?

    init() {
        if let saved = UserDefaults.standard.string(forKey: "phoneToken"), !saved.isEmpty {
            secret = saved
        } else {
            secret = LiveServer.newToken()
            UserDefaults.standard.set(secret, forKey: "phoneToken")
        }
    }

    /// The link the QR code holds: this Mac's address on the Wi-Fi. Many Android phones cannot
    /// find a Mac by its .local name, so the number it is reached at now goes in; the code is made
    /// again each time it shows. With no address, the .local name.
    var link: String? {
        let host = Self.wifiAddress() ?? (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
        guard let host else { return nil }
        return "https://\(host):\(Self.port)/\(lock.withLock { secret })/"
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

    var state: PhoneState {
        let now = CACurrentMediaTime()
        return queue.sync {
            let recent = arrivals.filter { now - $0 < 2 }
            return lock.withLock {
                PhoneState(serving: listener != nil, present: now - lastHeard < 3, connected: now - lastPicture < 2,
                           width: size.width, height: size.height,
                           fps: recent.count / 2, failure: failure)
            }
        }
    }

    /// Where the pictures go: compressed ones for the camera file, decoded ones for everything on
    /// screen, and the picture size whenever it changes. One recorder at a time; the newest wins.
    func deliver(to owner: AnyObject, compressed: @escaping (CMSampleBuffer) -> Void, decoded: @escaping (CMSampleBuffer) -> Void,
                 sized: @escaping (Int, Int) -> Void) {
        lock.withLock {
            self.owner = ObjectIdentifier(owner)
            self.compressed = compressed
            self.decoded = decoded
            self.sized = sized
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
        }
    }

    /// Asks the iPhone for a whole picture next, so a file can start on it.
    func askForKeyPicture() { lock.withLock { keyWanted = true } }

    /// While resting, the iPhone stops sending, which saves its battery and the Mac's work.
    func rest(_ on: Bool) { lock.withLock { resting = on } }

    /// Shown on the iPhone, so whoever holds it knows the take is rolling.
    func setRecording(_ on: Bool) { lock.withLock { recording = on } }

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
                    self.lock.withLock { self.listener = nil; self.failure = "The iPhone link stopped: \(error.localizedDescription)" }
                }
            }
            l.start(queue: queue)
            lock.withLock { listener = l; failure = nil }
        } catch {
            lock.withLock { failure = "The iPhone link could not start: \(error.localizedDescription)" }
        }
    }

    func stop() {
        lock.withLock { listener?.cancel(); listener = nil }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
    }

    /// Reads requests one after another on the same connection, so the iPhone keeps one secure
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

    private func answer(_ connection: NWConnection, _ request: Request) {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first, Self.same(first, lock.withLock { secret }) else {
            return send(connection, 404, "text/plain", Data("Not found".utf8))
        }
        let rest = parts.dropFirst().joined(separator: "/")
        switch (request.method, rest) {
        case ("GET", ""):
            send(connection, 200, "text/html; charset=utf-8", Data(PhonePage.html.utf8))
        case ("POST", "send"):
            take(request.body, from: request.headers["x-session"] ?? "")
        default:
            return send(connection, 404, "text/plain", Data("Not found".utf8))
        }
        // The reply carries the Mac's clock, so the iPhone can time its pictures on it.
        let (key, resting, recording) = lock.withLock { () -> (Bool, Bool, Bool) in
            defer { keyWanted = false }
            return (keyWanted, self.resting, self.recording)
        }
        let replaced = (request.headers["x-session"] ?? "") != session
        let reply = "{\"mac\":\(CACurrentMediaTime() * 1000),\"key\":\(key),\"rest\":\(resting),\"recording\":\(recording),\"replaced\":\(replaced)}"
        send(connection, 200, "application/json", Data(reply.utf8))
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

    // MARK: Pictures

    /// One batch from the iPhone. Each record is a kind byte, then for a format (1) the width and
    /// height (2 bytes each) and the H.264 settings (avcC, 4 byte length first), or for a picture (2)
    /// a whole-picture flag, the Mac time it was taken in milliseconds (8 byte float) and the
    /// picture (4 byte length first). Little endian throughout.
    private func take(_ body: Data, from sender: String) {
        // The newest page wins: a second iPhone, or the same one reloaded, takes over when it says
        // hello (an empty batch), and the one before it is told to stop.
        if sender != session, body.isEmpty, !sender.isEmpty {
            session = sender
            format = nil
            formatBytes = Data()
        }
        guard sender == session else { return }
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
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var session: VTDecompressionSession?
        if VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: made, decoderSpecification: nil,
                                        imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                        decompressionSessionOut: &session) == noErr {
            decoder = session
        }
        let changed = lock.withLock { () -> ((Int, Int) -> Void)? in
            defer { size = (width, height) }
            return size != (width, height) ? sized : nil
        }
        changed?(width, height)
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
        let (compressed, decoded) = lock.withLock { (self.compressed, self.decoded) }
        compressed?(sample)
        guard let decoded, let decoder else { return }
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

    // MARK: Certificate

    /// AVA's own certificate, made the first time with the Mac's built-in openssl and kept in
    /// Application Support. It is read into memory only, never into the keychain.
    private static func identity() throws -> SecIdentity {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AVA Recorder/iPhone link", isDirectory: true)
        let p12 = folder.appendingPathComponent("identity.p12")
        if !FileManager.default.fileExists(atPath: p12.path) {
            try make(p12, in: folder)
        }
        let data = try Data(contentsOf: p12)
        var items: CFArray?
        let options: [CFString: Any] = [kSecImportExportPassphrase: "ava", kSecImportToMemoryOnly: true]
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
                 "-subj", "/CN=AVA Recorder", "-addext", "subjectAltName=\(host)DNS:localhost"])
        try run(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path, "-passout", "pass:ava"])
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
