import AVFoundation
import Foundation
import Vision

// faces.json: her face in camera.mov, found by Vision, for the framing in Framing.swift. Only the
// stretches the finished video shows the camera across the frame are looked at, 5 times a second, on
// small copies of the pictures.
//
// Measured 8 Oct on an M5: Vision takes about 5 ms a look on the Neural Engine whatever the picture
// size, one look at a time (the GPU or the CPU beside it made it 4 to 6 times slower), so the number
// of looks sets the time: 5 a second is about 40 times faster than real time.

/// Looks per second of camera time.
let faceLooksPerSecond = 5.0

/// Looks for faces in `spans` of the movie (camera time, from and to, in seconds).
func detectFaces(in url: URL, spans wanted: [[Double]], looksPerSecond: Double = faceLooksPerSecond) throws -> FaceTrack {
    let first = AVURLAsset(url: url)
    let (natural, transform, range) = try waitFor { () -> (CGSize, CGAffineTransform, CMTimeRange) in
        guard let track = try await first.loadTracks(withMediaType: .video).first else { throw FinishError("camera.mov has no picture") }
        return try await track.load(.naturalSize, .preferredTransform, .timeRange)
    }
    let box = CGRect(origin: .zero, size: natural).applying(transform)
    let width = Int(abs(box.width).rounded()), height = Int(abs(box.height).rounded())
    guard width > 0, height > 0 else { throw FinishError("camera.mov has no picture") }
    let orientation = visionOrientation(transform)
    let end = range.end.seconds
    let spans = wanted.map { [max(range.start.seconds, $0[0]), min(end, $0[1])] }.filter { $0[1] > $0[0] + 0.05 }

    // 480 pixels on the long side, each side a multiple of 16: a 270 pixel wide picture made Vision
    // about 80 times slower (measured 8 Oct).
    let k = min(1, 480 / max(natural.width, natural.height, 1))
    func side(_ v: CGFloat) -> Int { max(16, Int((v * k / 16).rounded()) * 16) }
    let settings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelBufferWidthKey as String: side(natural.width),
        kCVPixelBufferHeightKey as String: side(natural.height),
    ]

    // The stretches cut into two pieces of about equal length, each read by its own decoder, so a
    // busy decoder never holds Vision up. Both keep looks on the same grid, 1/5 s apart.
    let step = 1 / looksPerSecond
    let total = spans.reduce(0) { $0 + $1[1] - $1[0] }
    var pieces: [[[Double]]] = [[], []]
    let share = total / Double(pieces.count)
    var piece = 0, filled = 0.0
    for span in spans {
        var from = span[0]
        while from < span[1] - 0.001 {
            let room = piece == pieces.count - 1 ? .greatestFiniteMagnitude : share - filled
            let to = min(span[1], from + max(room, step))
            pieces[piece].append([from, to])
            filled += to - from
            from = to
            if filled >= share - 0.001, piece < pieces.count - 1 { piece += 1; filled = 0 }
        }
    }

    final class Found: @unchecked Sendable {
        let lock = NSLock()
        var looks: [FaceLook] = []
        var problem: String?
    }
    let found = Found()
    DispatchQueue.concurrentPerform(iterations: pieces.count) { p in
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try waitFor({ try await asset.loadTracks(withMediaType: .video).first }) else { return }
            // Vision on a queue of its own, so the decoder carries on while it looks.
            let looker = DispatchQueue(label: "vidlark.faces.\(p)")
            let handler = VNSequenceRequestHandler(), request = VNDetectFaceRectanglesRequest()
            let inFlight = DispatchSemaphore(value: 2)
            let group = DispatchGroup()
            defer { group.wait() }
            for span in pieces[p] {
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = CMTimeRange(start: CMTime(seconds: span[0], preferredTimescale: 600),
                                               end: CMTime(seconds: span[1], preferredTimescale: 600))
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                output.alwaysCopiesSampleData = false
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? FinishError("unknown error") }
                // The first look on the grid at or after this piece's start.
                var next = (span[0] / step).rounded(.up) * step
                while let sample = output.copyNextSampleBuffer() {
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    guard t.isFinite, t >= next - 0.004, t < span[1], let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                    while next <= t + 0.004 { next += step }
                    inFlight.wait()
                    group.enter()
                    looker.async {
                        try? handler.perform([request], on: pixels, orientation: orientation)
                        // Vision's boxes are normalised with the origin bottom left; faces.json's top left.
                        let faces = (request.results ?? []).map { face -> FaceBox in
                            let b = face.boundingBox
                            return FaceBox(x: b.minX, y: 1 - b.maxY, w: b.width, h: b.height)
                        }
                        found.lock.withLock { found.looks.append(FaceLook(t: t, faces: faces)) }
                        inFlight.signal()
                        group.leave()
                    }
                }
                if reader.status == .failed { throw reader.error ?? FinishError("unknown error") }
            }
        } catch {
            found.lock.withLock { found.problem = (error as? FinishError)?.message ?? error.localizedDescription }
        }
    }
    if let problem = found.problem { throw FinishError("camera.mov could not be read for faces: \(problem)") }
    return FaceTrack(width: width, height: height, duration: end, looksPerSecond: looksPerSecond, spans: spans,
                     looks: found.looks.sorted { $0.t < $1.t })
}

/// Which way up the stored pictures are, for Vision, from the movie's turn.
private func visionOrientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
    switch (t.a.rounded(), t.b.rounded(), t.c.rounded(), t.d.rounded()) {
    case (0, 1, -1, 0): .right
    case (-1, 0, 0, -1): .down
    case (0, -1, 1, 0): .left
    default: .up
    }
}

/// Runs face detection on a thread of its own while the finisher gets on with the sound, so most of
/// its time is hidden. `wait` hands over the result.
final class FaceJob: @unchecked Sendable {
    private var result: Result<FaceTrack, Error>?
    private let done = DispatchSemaphore(value: 0)
    let started = Date()
    private(set) var seconds: Double = 0

    init(camera: URL, spans: [[Double]]) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            result = Result { try detectFaces(in: camera, spans: spans) }
            seconds = Date().timeIntervalSince(started)
            done.signal()
        }
    }

    func wait() -> Result<FaceTrack, Error> {
        done.wait()
        done.signal()
        return result!
    }
}
