import Accelerate
import Foundation

// MARK: - Extraction

// aresample with first_pts=0 pads any late audio start with silence, so sample 0 of each
// wav is time 0 of its movie, and async=1 fills gaps the same way.
func extractAudio(ffmpeg: String, input: String, outputs: [(path: String, rate: Int)],
                  startSeconds: Double? = nil, maxSeconds: Double? = nil) throws {
    var args = ["-nostdin", "-v", "error", "-y"]
    if let startSeconds { args += ["-ss", String(format: "%.3f", startSeconds)] }
    if let maxSeconds { args += ["-t", String(format: "%.1f", maxSeconds)] }
    args += ["-i", input]
    for output in outputs {
        args += [
            "-map", "0:a:0", "-vn",
            "-af", "aresample=\(output.rate):async=1:first_pts=0",
            "-ac", "1", "-ar", "\(output.rate)", "-c:a", "pcm_s16le",
            output.path,
        ]
    }
    let result = try runTool(ffmpeg, args)
    for output in outputs {
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        if result.status != 0 || size <= 44 {
            throw FinishError(result.lastErrorLine)
        }
    }
}

// MARK: - WAV reading (16-bit mono PCM, as written by extractAudio)

struct WavInfo {
    let sampleRate: Int
    let dataOffset: Int
    let sampleCount: Int
    var duration: Double { Double(sampleCount) / Double(sampleRate) }
}

func readWavInfo(_ data: Data) throws -> WavInfo {
    func u32(_ at: Int) -> Int {
        Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24
    }
    func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
    func tag(_ at: Int) -> String { String(decoding: data[at..<at + 4], as: UTF8.self) }

    guard data.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw FinishError("not a wav file") }
    var position = 12
    var rate = 0
    var channels = 0
    var bits = 0
    while position + 8 <= data.count {
        let id = tag(position)
        let size = u32(position + 4)
        let body = position + 8
        if id == "fmt " && body + 16 <= data.count {
            channels = u16(body + 2)
            rate = u32(body + 4)
            bits = u16(body + 14)
        } else if id == "data" {
            guard rate > 0, channels == 1, bits == 16 else { throw FinishError("unexpected wav format") }
            let available = data.count - body
            let bytes = (size == 0 || size > available) ? available : size
            return WavInfo(sampleRate: rate, dataOffset: body, sampleCount: bytes / 2)
        }
        position = body + size + (size & 1)
    }
    throw FinishError("wav file has no audio data")
}

func readWav(_ url: URL, maxSeconds: Double? = nil) throws -> (samples: [Float], info: WavInfo) {
    let data = try Data(contentsOf: url, options: .alwaysMapped)
    let info = try readWavInfo(data)
    var count = info.sampleCount
    if let maxSeconds { count = min(count, Int(maxSeconds * Double(info.sampleRate))) }
    var ints = [Int16](repeating: 0, count: count)
    ints.withUnsafeMutableBytes { dest in
        data.withUnsafeBytes { src in
            dest.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[info.dataOffset..<info.dataOffset + count * 2]))
        }
    }
    var floats = [Float](repeating: 0, count: count)
    vDSP_vflt16(ints, 1, &floats, 1, vDSP_Length(count))
    var scale: Float = 1.0 / 32768.0
    vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(count))
    return (floats, info)
}

// MARK: - Sync

struct SyncResult {
    let offset: Double      // camera_t = screen_t + offset
    let method: String      // "audio" or "none"
    let confidence: Double  // 0...1
    let note: String?
}

/// An extra camera file (camera-2.mov and on). Its offset means camera_t = this file's t + offset.
struct ExtraCameraSync {
    var file: String
    var duration: Double?
    var sync: SyncResult
}

// RMS loudness of consecutive frames, returned as Double for the correlation sums.
func loudnessEnvelope(_ samples: [Float], frameLength: Int) -> [Double] {
    let frames = samples.count / frameLength
    var envelope = [Double](repeating: 0, count: frames)
    samples.withUnsafeBufferPointer { buffer in
        for i in 0..<frames {
            var rms: Float = 0
            vDSP_rmsqv(buffer.baseAddress! + i * frameLength, 1, &rms, vDSP_Length(frameLength))
            envelope[i] = Double(rms)
        }
    }
    return envelope
}

// Finds lag d (in frames) where camera[k] best matches screen[k - d], using the Pearson
// correlation over the overlap at each lag. Returns the lag in frames (with sub-frame
// refinement) and the peak correlation.
func bestLag(camera: [Double], screen: [Double], maxLag: Int, minOverlap: Int) -> (lag: Double, correlation: Double)? {
    func prefixSums(_ x: [Double]) -> (sum: [Double], sq: [Double]) {
        var sum = [Double](repeating: 0, count: x.count + 1)
        var sq = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count {
            sum[i + 1] = sum[i] + x[i]
            sq[i + 1] = sq[i] + x[i] * x[i]
        }
        return (sum, sq)
    }
    // Centre both signals so the sums stay well conditioned.
    let cMean = vDSP.mean(camera)
    let sMean = vDSP.mean(screen)
    let c = vDSP.add(-cMean, camera)
    let s = vDSP.add(-sMean, screen)
    let cp = prefixSums(c)
    let sp = prefixSums(s)

    var scores = [Double](repeating: -2, count: 2 * maxLag + 1)
    c.withUnsafeBufferPointer { cb in
        s.withUnsafeBufferPointer { sb in
            for d in -maxLag...maxLag {
                let start = max(0, d)
                let end = min(c.count, s.count + d)
                let n = end - start
                if n < minOverlap { continue }
                var dot = 0.0
                vDSP_dotprD(cb.baseAddress! + start, 1, sb.baseAddress! + (start - d), 1, &dot, vDSP_Length(n))
                let count = Double(n)
                let sumC = cp.sum[end] - cp.sum[start]
                let sumC2 = cp.sq[end] - cp.sq[start]
                let sumS = sp.sum[end - d] - sp.sum[start - d]
                let sumS2 = sp.sq[end - d] - sp.sq[start - d]
                let varC = sumC2 - sumC * sumC / count
                let varS = sumS2 - sumS * sumS / count
                if varC <= 1e-12 || varS <= 1e-12 { continue }
                scores[d + maxLag] = (dot - sumC * sumS / count) / (varC * varS).squareRoot()
            }
        }
    }
    guard let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[bestIndex] > -2 else {
        return nil
    }
    var refined = Double(bestIndex)
    if bestIndex > 0, bestIndex < scores.count - 1, scores[bestIndex - 1] > -2, scores[bestIndex + 1] > -2 {
        let a = scores[bestIndex - 1], b = scores[bestIndex], cc = scores[bestIndex + 1]
        let denominator = a - 2 * b + cc
        if denominator < 0 { refined += 0.5 * (a - cc) / denominator }
    }
    return (refined - Double(maxLag), scores[bestIndex])
}

func measureSync(cameraWav: URL, screenWav: URL, maxLagSeconds: Double = 3) throws -> SyncResult {
    let window = 120.0
    let camera = try readWav(cameraWav, maxSeconds: window)
    let screen = try readWav(screenWav, maxSeconds: window + maxLagSeconds)
    let frameLength = max(1, camera.info.sampleRate / 1000)  // 1 ms frames
    let frameSeconds = Double(frameLength) / Double(camera.info.sampleRate)
    let cameraEnvelope = loudnessEnvelope(camera.samples, frameLength: frameLength)
    let screenEnvelope = loudnessEnvelope(screen.samples, frameLength: frameLength)
    let maxLag = Int(maxLagSeconds / frameSeconds)
    let minOverlap = Int(2.0 / frameSeconds)
    guard let match = bestLag(camera: cameraEnvelope, screen: screenEnvelope, maxLag: maxLag, minOverlap: minOverlap) else {
        return SyncResult(offset: 0, method: "none", confidence: 0,
                          note: "the two sound tracks are silent or too short to match")
    }
    return SyncResult(offset: match.lag * frameSeconds, method: "audio",
                      confidence: min(1, max(0, match.correlation)), note: nil)
}
