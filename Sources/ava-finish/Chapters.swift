import Foundation

struct RecordingEvents {
    var title: String?
    var wall: String?
    var cards: [(t: Double, section: String)] = []
    var apps: [(t: Double, name: String)] = []
    var stopTime: Double?
    /// The take started with the camera only (its start line names no screen file).
    var cameraFirst = false
    /// When the screen was shared in a camera-first take, in camera time.
    var screenShared: Double?
    /// Each click of Me or Screen, in camera time. The first is where the take started.
    var shows: [ShowChange] = []
    /// Each change of the Mac's sound: on or off, and from where.
    var sounds: [(t: Double, on: Bool, from: String)] = []
    var skippedLines = 0
}

// Reads events.jsonl line by line. A crash can leave a cut-off last line or no stop line,
// so any line that is not a whole JSON object is counted and skipped.
func readEvents(_ url: URL) -> RecordingEvents? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    var events = RecordingEvents()
    for line in data.split(separator: UInt8(ascii: "\n")) {
        let trimmed = line.filter { $0 != 0 && $0 != UInt8(ascii: "\r") }
        if trimmed.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }) { continue }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed)) as? [String: Any],
              let type = object["type"] as? String
        else {
            events.skippedLines += 1
            continue
        }
        let t = (object["t"] as? NSNumber)?.doubleValue ?? 0
        func text(_ key: String) -> String? {
            let value = (object[key] as? String)?
                .components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return (value?.isEmpty ?? true) ? nil : value
        }
        switch type {
        case "start":
            events.title = text("title")
            events.wall = text("wall")
            events.cameraFirst = (object["screen"] as? String) == ""
        case "screen-start":
            if events.screenShared == nil { events.screenShared = t }
        case "sound":
            events.sounds.append((t, (object["on"] as? Bool) ?? false, text("from") ?? "every app"))
        case "show":
            if let what = text("what") { events.shows.append(ShowChange(t: t, screen: what == "screen")) }
        case "card":
            if let section = text("section") { events.cards.append((t, section)) }
        case "app":
            if let name = text("name") { events.apps.append((t, name)) }
        case "stop":
            events.stopTime = t
        default:
            break
        }
    }
    return events
}

struct Chapter {
    var t: Double
    var title: String
}

// Sections from prompter cards when there are any, otherwise app switches.
func rawChapters(_ events: RecordingEvents) -> (chapters: [Chapter], source: String) {
    func changes(_ items: [(t: Double, label: String)]) -> [Chapter] {
        var result: [Chapter] = []
        for item in items.sorted(by: { $0.t < $1.t }) where result.last?.title != item.label {
            result.append(Chapter(t: item.t, title: item.label))
        }
        return result
    }
    if !events.cards.isEmpty {
        return (changes(events.cards.map { ($0.t, $0.section) }), "prompter sections")
    }
    return (changes(events.apps.map { ($0.t, $0.name) }), "app switches")
}

// YouTube rules: the first chapter at 00:00, at least 3 chapters, each at least 10 seconds.
// The shortest chapter under 10 seconds is folded into the one before it (the first one into
// the one after it), then repeated, so a brief detour between two parts of the same section
// disappears and the section joins back up.
func youTubeChapters(_ input: [Chapter], end: Double?) -> [Chapter] {
    let minimum = 10.0
    var chapters = input.filter { end == nil || $0.t < end! }
    guard !chapters.isEmpty else { return [] }
    chapters[0].t = 0
    while true {
        var i = 1
        while i < chapters.count {
            if chapters[i].title == chapters[i - 1].title { chapters.remove(at: i) } else { i += 1 }
        }
        var short: Int?
        var shortest = minimum
        for index in chapters.indices {
            guard let next = index + 1 < chapters.count ? chapters[index + 1].t : end else { continue }
            let duration = next - chapters[index].t
            if duration < shortest {
                shortest = duration
                short = index
            }
        }
        guard let short, chapters.count > 1 else { break }
        if short == 0 {
            chapters.remove(at: 0)
            chapters[0].t = 0
        } else {
            chapters.remove(at: short)
        }
    }
    return chapters.count >= 3 ? chapters : []
}

func chaptersText(_ chapters: [Chapter]) -> String {
    chapters.map { "\(clock($0.t)) \(noEmDash($0.title))\n" }.joined()
}
