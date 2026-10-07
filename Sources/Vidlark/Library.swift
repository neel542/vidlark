import Foundation
import QuartzCore

/// A video waiting to be filmed today. The queue lives in /Users/Shared so it is the same
/// whichever Mac user account is logged in.
struct VideoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var script: String
    var folder: String?
    var recordings = 0
    var added = Date()

    var parsed: Script { Script.parse(script, fallbackTitle: title) }
}

enum Library {
    static let root = URL(fileURLWithPath: "/Users/Shared/Vidlark Recordings", isDirectory: true)
    private static var queueFile: URL { root.appendingPathComponent("queue.json") }

    static func makeDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        }
        // Shared on purpose: Neel's and the presenter's accounts both write here.
        try? fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: url.path)
    }

    static func loadQueue() -> [VideoItem] {
        guard let data = try? Data(contentsOf: queueFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([VideoItem].self, from: data)) ?? []
    }

    static func saveQueue(_ items: [VideoItem]) {
        try? makeDirectory(root)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: queueFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: queueFile.path)
    }

    static func safeName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "Untitled" : short
    }

    /// `<root>/<date> <title>/recording-N/`
    static func newRecordingFolder(for item: inout VideoItem?) throws -> URL {
        let videoFolder: URL
        if let existing = item?.folder, FileManager.default.fileExists(atPath: existing) {
            videoFolder = URL(fileURLWithPath: existing, isDirectory: true)
        } else {
            let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withDashSeparatorInDate])
            let title = item.map { $0.parsed.title } ?? "Quick recording \(timeStamp())"
            videoFolder = uniqueFolder(root.appendingPathComponent("\(day) \(safeName(title))", isDirectory: true))
            item?.folder = videoFolder.path
        }
        try makeDirectory(videoFolder)

        let existing = (try? FileManager.default.contentsOfDirectory(atPath: videoFolder.path)) ?? []
        var n = existing.filter { $0.hasPrefix("recording-") }.count + 1
        var folder = videoFolder.appendingPathComponent("recording-\(n)", isDirectory: true)
        while FileManager.default.fileExists(atPath: folder.path) {
            n += 1
            folder = videoFolder.appendingPathComponent("recording-\(n)", isDirectory: true)
        }
        try makeDirectory(folder)
        return folder
    }

    /// Adds " (2)", " (3)" and so on until nothing on disk has the name.
    static func uniqueFolder(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) (\(n))", isDirectory: true)
            n += 1
        }
        return candidate
    }

    private static func timeStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH.mm"
        return f.string(from: Date())
    }
}

/// Appends one JSON object per line and writes it straight to disk, so a crash keeps the log.
final class EventLog {
    private let handle: FileHandle
    let t0: CFTimeInterval

    init?(url: URL, t0: CFTimeInterval) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        self.t0 = t0
    }

    func write(_ fields: [String: Any], at time: CFTimeInterval = CACurrentMediaTime()) {
        var object = fields
        object["t"] = (max(0, time - t0) * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    func close() { try? handle.close() }
}
