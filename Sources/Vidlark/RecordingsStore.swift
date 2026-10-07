import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The files behind the Recordings page: finding every take on disk, its thumbnail, and the three
// changes the page can make (rename, save a copy, move to the Trash). Nothing here touches the UI,
// so it can be checked against a fake library (Tests/recordings).

/// One take: a `recording-N` folder inside a video folder, or one Neel has renamed.
struct TakeInfo: Identifiable, Equatable, Sendable {
    var folder: URL
    /// What the card shows: the name Neel gave the take, otherwise the video's title.
    var title: String
    /// The title the take was filmed under.
    var videoTitle: String
    /// N from `recording-N`. Nil once the take has a name of its own.
    var number: Int?
    var renamed: Bool
    var date: Date
    var duration: TimeInterval?
    var bytes: Int64
    var hasCamera: Bool
    var hasScreen: Bool
    /// The finisher has written report.md.
    var finished: Bool
    /// The newest change to a recording file in the folder.
    var lastWrite: Date
    /// A file changed in the 10 seconds before the scan, so it is being recorded or finished now.
    var writing: Bool

    var id: String { folder.path }

    /// Something missing, said plainly. Nil when the take is whole.
    var warning: String? {
        if !hasCamera && !hasScreen { return "No video files" }
        if !hasCamera { return "No camera file" }
        if !hasScreen { return "No screen file" }
        return nil
    }

    /// Used in confirmations, so two takes of one video are never confused.
    var fullName: String { number.map { "\(title), take \($0)" } ?? title }

    /// The folder name for a saved copy: date, title and take, so it makes sense on its own.
    var copyName: String {
        let day = TakeStore.dayFormatter.string(from: date)
        return "\(day) \(Library.safeName(title))" + (number.map { " - Take \($0)" } ?? "")
    }
}

struct TakeError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum TakeStore {
    static let thumbnailName = "thumbnail.jpg"
    /// The exact name Neel typed. The folder holds a safe version of it.
    static let nameFile = ".title"
    static let writingWindow: TimeInterval = 10

    /// What a take's events and videos said last time, so an unchanged take is not read again.
    struct Cached: Sendable {
        var stamp: String
        var title: String?
        var wall: Date?
        var duration: TimeInterval?
        /// True when the duration came from the stop line, so the video need not be opened.
        var exact: Bool
        var videoChecked = false
    }
    typealias Cache = [String: Cached]

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: Scan

    /// Every take under `root`, newest first. Looks two levels down and skips dot folders such as `.models`.
    static func scan(root: URL, cache: Cache = [:], now: Date = Date()) async -> (takes: [TakeInfo], cache: Cache) {
        var (takes, fresh) = scanFiles(root: root, cache: cache, now: now)
        // A take that crashed has no stop line: ask the video how long it is, once.
        for i in takes.indices where !takes[i].writing {
            let key = takes[i].id
            guard var entry = fresh[key], !entry.exact, !entry.videoChecked else { continue }
            entry.videoChecked = true
            for name in ["camera.mov", "screen.mov"] {
                let url = takes[i].folder.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite, seconds > 0 {
                    entry.duration = seconds
                    break
                }
            }
            takes[i].duration = entry.duration
            fresh[key] = entry
        }
        return (takes, fresh)
    }

    static func scanFiles(root: URL, cache: Cache, now: Date) -> (takes: [TakeInfo], cache: Cache) {
        var takes: [TakeInfo] = []
        var fresh: Cache = [:]
        for level1 in subfolders(of: root) {
            if isTake(level1), let take = read(level1, video: nil, cache: cache, into: &fresh, now: now) {
                takes.append(take)
            }
            for level2 in subfolders(of: level1) where isTake(level2) {
                if let take = read(level2, video: level1, cache: cache, into: &fresh, now: now) { takes.append(take) }
            }
        }
        takes.sort { $0.date > $1.date }
        return (takes, fresh)
    }

    static func isTake(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return ["camera.mov", "screen.mov", "events.jsonl"].contains { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    private static func subfolders(of url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter {
            let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }
    }

    /// Recording files only: our own thumbnail, the name file and Finder's files do not count as writing.
    private static func countsAsWriting(_ name: String) -> Bool {
        !name.hasPrefix(".") && name != thumbnailName
    }

    private static let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey,
                                                        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]

    private struct Files {
        var bytes: Int64 = 0
        var lastWrite = Date.distantPast
        var top: [String: (modified: Date?, created: Date?, size: Int)] = [:]
    }

    private static func files(in folder: URL) -> Files {
        var out = Files()
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(fileKeys)) else { return out }
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: fileKeys), v.isRegularFile == true else { continue }
            out.bytes += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
            let name = url.lastPathComponent
            if countsAsWriting(name), let modified = v.contentModificationDate, modified > out.lastWrite {
                out.lastWrite = modified
            }
            if walker.level == 1 {
                out.top[name] = (v.contentModificationDate, v.creationDate, v.fileSize ?? 0)
            }
        }
        return out
    }

    /// The newest change to a recording file in the folder.
    static func lastWrite(in folder: URL) -> Date { files(in: folder).lastWrite }

    /// True while the folder is being recorded or finished: a file changed in the last 10 seconds.
    static func isBeingWritten(_ folder: URL, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastWrite(in: folder)) < writingWindow
    }

    private static func read(_ folder: URL, video: URL?, cache: Cache, into fresh: inout Cache, now: Date) -> TakeInfo? {
        let found = files(in: folder)
        let events = found.top["events.jsonl"], camera = found.top["camera.mov"], screen = found.top["screen.mov"]
        func mark(_ f: (modified: Date?, created: Date?, size: Int)?) -> String {
            guard let f else { return "-" }
            return "\(f.modified?.timeIntervalSince1970 ?? 0):\(f.size)"
        }
        let stamp = [mark(events), mark(camera), mark(screen)].joined(separator: "|")

        var entry: Cached
        if let old = cache[folder.path], old.stamp == stamp {
            entry = old
        } else {
            let log = readEvents(folder.appendingPathComponent("events.jsonl"))
            entry = Cached(stamp: stamp, title: log.title, wall: log.wall, duration: log.stop ?? log.lastT, exact: log.stop != nil)
        }
        fresh[folder.path] = entry

        let folderName = folder.lastPathComponent
        let number = recordingNumber(folderName)
        let videoTitle = entry.title ?? stripDay(video?.lastPathComponent ?? folderName)
        var title = videoTitle
        var renamed = false
        if let saved = savedName(in: folder), matches(folderName, Library.safeName(saved)) {
            title = saved
            renamed = true
        } else if number == nil, video != nil {
            // Renamed in Finder, or by an older build: the folder name is the name.
            title = folderName
            renamed = true
        }

        let folderCreated = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        let date = entry.wall ?? camera?.created ?? screen?.created ?? folderCreated ?? found.lastWrite
        let writing = now.timeIntervalSince(found.lastWrite) < writingWindow
        return TakeInfo(folder: folder, title: title, videoTitle: videoTitle, number: renamed ? nil : number,
                        renamed: renamed, date: date, duration: entry.duration, bytes: found.bytes,
                        hasCamera: camera != nil, hasScreen: screen != nil,
                        finished: found.top["report.md"] != nil, lastWrite: found.lastWrite, writing: writing)
    }

    struct EventSummary {
        var title: String?
        var wall: Date?
        var stop: Double?
        var lastT: Double?
    }

    /// The start line gives the title and the time; the stop line gives the length. A crash can
    /// leave a cut-off last line, so any line that is not whole JSON is skipped.
    static func readEvents(_ url: URL) -> EventSummary {
        var out = EventSummary()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return out }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let t = (object["t"] as? NSNumber)?.doubleValue
            if let t, t.isFinite { out.lastT = max(out.lastT ?? 0, t) }
            switch object["type"] as? String {
            case "start":
                if let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    out.title = title
                }
                if let wall = object["wall"] as? String { out.wall = parseDate(wall) }
            case "stop":
                out.stop = t
            default:
                break
            }
        }
        return out
    }

    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func recordingNumber(_ name: String) -> Int? {
        guard name.hasPrefix("recording-") else { return nil }
        return Int(name.dropFirst("recording-".count))
    }

    /// "2026-10-04 How to fix a listing" becomes "How to fix a listing".
    static func stripDay(_ name: String) -> String {
        let parts = name.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 10, dayFormatter.date(from: String(parts[0])) != nil else { return name }
        return String(parts[1])
    }

    private static func savedName(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(nameFile)),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// The folder is still named after the saved name: exactly, or with " (2)" added to keep it unique.
    private static func matches(_ folderName: String, _ safe: String) -> Bool {
        folderName == safe || (folderName.hasPrefix(safe + " (") && folderName.hasSuffix(")"))
    }

    // MARK: Changes

    /// Renames the take folder inside its video folder and keeps the exact name for the card.
    @discardableResult
    static func rename(_ folder: URL, to newName: String, now: Date = Date()) throws -> URL {
        let name = newName.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw TakeError("Type a name first.") }
        guard !isBeingWritten(folder, now: now) else { throw TakeError("This take is still being written. Try again in a few seconds.") }
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        let safe = Library.safeName(name)
        var target = folder
        if !matches(folder.lastPathComponent, safe) {
            let wanted = parent.appendingPathComponent(safe, isDirectory: true)
            if folder.lastPathComponent.caseInsensitiveCompare(safe) == .orderedSame {
                // Only the capitals change. The disk ignores case, so step through a temporary name.
                let step = parent.appendingPathComponent(".renaming-\(UUID().uuidString)", isDirectory: true)
                try fm.moveItem(at: folder, to: step)
                do { try fm.moveItem(at: step, to: wanted) } catch {
                    try? fm.moveItem(at: step, to: folder)
                    throw error
                }
                target = wanted
            } else {
                target = Library.uniqueFolder(wanted)
                try fm.moveItem(at: folder, to: target)
            }
        }
        try? Data(name.utf8).write(to: target.appendingPathComponent(nameFile), options: .atomic)
        return target
    }

    /// Moves the whole take folder to the Trash. Never deletes outright.
    @discardableResult
    static func moveToTrash(_ folder: URL, now: Date = Date()) throws -> URL? {
        guard !isBeingWritten(folder, now: now) else { throw TakeError("This take is still being written. Try again in a few seconds.") }
        var landed: NSURL?
        try FileManager.default.trashItem(at: folder, resultingItemURL: &landed)
        return landed as URL?
    }

    /// Copies the whole take folder into `directory` under `name`, kept unique. Blocks, so call it off the main thread.
    static func copy(_ folder: URL, named name: String, into directory: URL, now: Date = Date()) throws -> URL {
        guard !isBeingWritten(folder, now: now) else { throw TakeError("This take is still being written. Try again in a few seconds.") }
        let source = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let destination = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard destination != source, !destination.hasPrefix(source + "/") else {
            throw TakeError("Choose a folder outside this take.")
        }
        let fm = FileManager.default
        let target = Library.uniqueFolder(directory.appendingPathComponent(name, isDirectory: true))
        do {
            try fm.copyItem(at: folder, to: target)
        } catch {
            // Only our own half-made copy is removed; the take itself is untouched.
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            throw error
        }
        return target
    }

    // MARK: Thumbnail

    /// The take's thumbnail.jpg, made once from one frame of the camera (about 3 s in), else the screen.
    static func thumbnail(for folder: URL, maxPixels: Int = 640) async -> CGImage? {
        let file = folder.appendingPathComponent(thumbnailName)
        if let image = readImage(file, maxPixels: maxPixels) { return image }
        guard !Task.isCancelled, !isBeingWritten(folder) else { return nil }
        let extras = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("camera-") && $0.hasSuffix(".mov") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in ["camera.mov", "screen.mov"] + extras {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let image = await frame(of: url, maxPixels: maxPixels) {
                writeJPEG(image, to: file)
                return image
            }
        }
        return nil
    }

    /// One frame, decoded at thumbnail size. Near a keyframe is close enough and much faster.
    static func frame(of url: URL, maxPixels: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return nil }
        let length = (try? await asset.load(.duration))?.seconds ?? 0
        let at = length.isFinite && length > 0 ? min(3, length / 2) : 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)).image
    }

    static func readImage(_ url: URL, maxPixels: Int) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Written under a temporary dot name, then moved into place, so a half-written file is never read.
    static func writeJPEG(_ image: CGImage, to url: URL) {
        let fm = FileManager.default
        let step = url.deletingLastPathComponent().appendingPathComponent(".thumbnail-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(step as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { try? fm.removeItem(at: step); return }
        // Shared on purpose, like the rest of the library: either account can replace it.
        try? fm.setAttributes([.posixPermissions: 0o666], ofItemAtPath: step.path)
        do {
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: step) } else { try fm.moveItem(at: step, to: url) }
        } catch {
            try? fm.removeItem(at: step)
        }
    }
}
