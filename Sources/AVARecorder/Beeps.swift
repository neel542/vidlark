import AppKit

/// The countdown sound: a short beep on 3, 2 and 1, and a higher, longer one on "go".
/// Made in code, so there are no sound files to ship. The editor cuts these 3 seconds anyway.
enum Beeps {
    private static let tick = tone(hertz: 880, seconds: 0.12)
    private static let start = tone(hertz: 1320, seconds: 0.35)

    static func count() { play(tick) }
    static func go() { play(start) }

    private static func play(_ sound: NSSound?) {
        guard !Snapshots.active, let sound else { return }
        sound.stop()
        sound.play()
    }

    /// A sine tone with soft edges, as an in-memory 16-bit mono WAV.
    private static func tone(hertz: Double, seconds: Double) -> NSSound? {
        let rate = 44_100
        let count = Int(Double(rate) * seconds)
        let fade = Double(rate) * 0.01
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let edge = min(1, Double(i) / fade, Double(count - i) / fade)
            samples[i] = Int16(sin(2 * .pi * hertz * Double(i) / Double(rate)) * edge * 0.35 * Double(Int16.max))
        }
        var wav = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + count * 2))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); put(UInt32(count * 2))
        samples.forEach { put($0) }
        return NSSound(data: wav)
    }
}
