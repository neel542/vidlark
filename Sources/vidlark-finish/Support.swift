import Foundation

struct FinishError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// The app starts this tool without a shell PATH, so look in the usual Homebrew places first.
enum Tools {
    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func find(_ name: String) -> String? {
        var dirs = searchDirs
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func require(_ name: String) throws -> String {
        guard let path = find(name) else {
            throw FinishError("\(name) not found (looked in \(searchDirs.joined(separator: ", ")) and PATH)")
        }
        return path
    }
}

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var lastErrorLine: String {
        let lines = String(decoding: stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last ?? "exit code \(status)"
    }
}

func runTool(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()

    // Read both pipes at once so a chatty tool cannot fill one and stall.
    var outData = Data()
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.wait()
    process.waitUntilExit()
    return ProcessResult(status: process.terminationStatus, stdout: outData, stderr: errData)
}

// MARK: - Media probing

struct MediaInfo {
    let duration: Double?
    let hasAudio: Bool
}

func probeMedia(_ ffprobe: String, _ path: String) throws -> MediaInfo {
    let result = try runTool(ffprobe, [
        "-v", "error",
        "-show_entries", "format=duration:stream=codec_type,duration",
        "-of", "json", path,
    ])
    guard result.status == 0,
          let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
    else {
        throw FinishError(result.lastErrorLine)
    }
    let streams = json["streams"] as? [[String: Any]] ?? []
    let hasAudio = streams.contains { ($0["codec_type"] as? String) == "audio" }
    var duration = Double((json["format"] as? [String: Any])?["duration"] as? String ?? "")
    if duration == nil || duration == 0 {
        duration = streams.compactMap { Double($0["duration"] as? String ?? "") }.max()
    }
    if streams.isEmpty {
        throw FinishError("no audio or video found in the file")
    }
    return MediaInfo(duration: duration, hasAudio: hasAudio)
}

// MARK: - Output helpers

func jsonString(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

func jsonNumber(_ value: Double, places: Int = 3) -> String {
    let text = String(format: "%.\(places)f", value)
    if Double(text) == 0 { return String(format: "%.\(places)f", 0.0) }
    return text
}

// MM:SS, or H:MM:SS from one hour on. Seconds are rounded down, as YouTube expects.
func clock(_ seconds: Double) -> String {
    let total = Int(max(0, seconds).rounded(.down))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

// Neel's hard rule: no em dashes in anything this tool writes.
func noEmDash(_ text: String) -> String {
    text.replacingOccurrences(of: " \u{2014} ", with: ", ")
        .replacingOccurrences(of: "\u{2014}", with: ", ")
}

func writeText(_ text: String, to url: URL) throws {
    try noEmDash(text).write(to: url, atomically: true, encoding: .utf8)
}
