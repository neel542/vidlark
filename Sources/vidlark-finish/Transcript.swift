import Foundation

struct Word {
    var word: String
    var start: Double
    var end: Double
}

struct Retake {
    let t: Double
    let context: String
}

/// The compressed model first: same words on the test recording, under half the memory
/// (790 MB against 1.8 GB). The full model is the fallback.
let modelFileNames = ["ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo.bin"]

func findModel(override: String?) -> (path: String?, searched: [String]) {
    if let override { return (FileManager.default.isReadableFile(atPath: override) ? override : nil, [override]) }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let dirs = [
        (home as NSString).appendingPathComponent(".cache/whisper"),
        "/Users/Shared/Vidlark Recordings/.models",
    ]
    let candidates = modelFileNames.flatMap { name in dirs.map { ($0 as NSString).appendingPathComponent(name) } }
    return (candidates.first { FileManager.default.isReadableFile(atPath: $0) }, candidates)
}

// whisper.cpp alignment-head presets, matched from the model file name.
func dtwPreset(forModel path: String) -> String? {
    var name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    if name.hasPrefix("ggml-") { name.removeFirst(5) }
    if let range = name.range(of: #"-q\d.*$"#, options: .regularExpression) { name.removeSubrange(range) }
    name = name.replacingOccurrences(of: "-", with: ".")
    let known = ["tiny", "tiny.en", "base", "base.en", "small", "small.en", "medium", "medium.en",
                 "large.v1", "large.v2", "large.v3", "large.v3.turbo"]
    return known.contains(name) ? name : nil
}

func transcribe(whisper: String, model: String, wav: URL, workDir: URL) throws -> [Word] {
    let outBase = workDir.appendingPathComponent("whisper")
    let threads = min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))
    var args = ["-m", model, "-f", wav.path, "-l", "en", "-ojf", "-of", outBase.path, "-t", "\(threads)"]
    let preset = dtwPreset(forModel: model)
    // DTW gives far better word times, and whisper.cpp only runs it with flash attention off.
    if let preset { args += ["-dtw", preset, "-nfa"] }
    let result = try runTool(whisper, args)
    let jsonURL = outBase.appendingPathExtension("json")
    guard result.status == 0, let raw = try? Data(contentsOf: jsonURL) else {
        throw FinishError("whisper-cli failed: \(result.lastErrorLine)")
    }
    // whisper can split a multi-byte character across tokens, so repair the text before parsing.
    let repaired = Data(String(decoding: raw, as: UTF8.self).utf8)
    guard let json = try? JSONSerialization.jsonObject(with: repaired) as? [String: Any],
          let segments = json["transcription"] as? [[String: Any]]
    else {
        throw FinishError("could not read whisper-cli output")
    }
    return buildWords(segments: segments, useDTW: preset != nil)
}

private func hasLetterOrDigit(_ text: String) -> Bool {
    text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
}

func buildWords(segments: [[String: Any]], useDTW: Bool) -> [Word] {
    struct Building {
        var text: String
        var start: Double
        var end: Double?
        var lastEnd: Double
    }
    var built: [Building] = []
    var previousEnd: Double?

    for segment in segments {
        let segmentStart = ((segment["offsets"] as? [String: Any])?["from"] as? NSNumber)?.doubleValue ?? 0
        for token in segment["tokens"] as? [[String: Any]] ?? [] {
            var text = (token["text"] as? String ?? "").replacingOccurrences(of: "\u{FFFD}", with: "")
            if text.isEmpty || (text.hasPrefix("[_") && text.hasSuffix("]")) { continue }
            let offsets = token["offsets"] as? [String: Any]
            let from = (offsets?["from"] as? NSNumber)?.doubleValue ?? segmentStart
            let to = (offsets?["to"] as? NSNumber)?.doubleValue ?? from
            var start = from / 1000
            var end = to / 1000
            if useDTW, let dtw = (token["t_dtw"] as? NSNumber)?.doubleValue, dtw >= 0 {
                // t_dtw marks where the token ends, in hundredths of a second.
                end = dtw / 100
                start = min(previousEnd ?? segmentStart / 1000, end)
            }
            previousEnd = end

            let startsWord = text.hasPrefix(" ") || built.isEmpty
            let isWordy = hasLetterOrDigit(text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if startsWord && (isWordy || built.isEmpty) {
                built.append(Building(text: text, start: start, end: isWordy ? end : nil, lastEnd: end))
            } else {
                built[built.count - 1].text += text
                built[built.count - 1].lastEnd = end
                if isWordy { built[built.count - 1].end = end }
            }
        }
    }

    var words = built.compactMap { b -> Word? in
        let text = b.text
        if (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")")) { return nil }
        if !hasLetterOrDigit(text) { return nil }
        return Word(word: text, start: b.start, end: max(b.start, b.end ?? b.lastEnd))
    }

    // A word that follows a pause soaks up the silence before it. Cap such words at twice the
    // typical word length, the same fix OpenAI's whisper uses at sentence boundaries.
    let durations = words.map { $0.end - $0.start }.filter { $0 > 0 }.sorted()
    if !durations.isEmpty {
        let median = durations[durations.count / 2]
        let maxDuration = 2 * min(0.7, max(0.1, median))
        for i in words.indices {
            let duration = words[i].end - words[i].start
            guard duration > maxDuration else { continue }
            let afterBreak = i == 0 || words[i - 1].word.last.map { ".!?,;:".contains($0) } == true
            if afterBreak || duration > 2 * maxDuration {
                words[i].start = words[i].end - maxDuration
            }
        }
    }
    for i in words.indices {
        if i > 0 && words[i].start < words[i - 1].start { words[i].start = words[i - 1].start }
        if words[i].end < words[i].start { words[i].end = words[i].start }
    }
    return words
}

func wordsJSON(_ words: [Word]) -> String {
    let lines = words.map {
        "{\"word\":\(jsonString($0.word)),\"start\":\(jsonNumber($0.start)),\"end\":\(jsonNumber($0.end))}"
    }
    return lines.isEmpty ? "[]\n" : "[\n" + lines.joined(separator: ",\n") + "\n]\n"
}

// MARK: - Retakes

private func letters(_ word: String) -> String {
    String(word.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) }.map(Character.init))
}

func findRetakes(_ words: [Word]) -> [Retake] {
    let plain = words.map { letters($0.word) }
    var found: [Retake] = []
    var i = 0
    while i < words.count {
        var hit = plain[i] == "retake"
        var span = 1
        if !hit && plain[i] == "re" && i + 1 < words.count && plain[i + 1] == "take" {
            hit = true
            span = 2
        }
        if hit {
            let before = words[max(0, i - 12)..<i].map(\.word).joined(separator: " ")
            found.append(Retake(t: words[i].start, context: before.isEmpty ? "[RETAKE]" : before + " [RETAKE]"))
        }
        i += span
    }
    return found
}

func retakesJSON(_ retakes: [Retake]) -> String {
    let lines = retakes.map { "{\"t\":\(jsonNumber($0.t)),\"context\":\(jsonString($0.context))}" }
    return lines.isEmpty ? "[]\n" : "[\n" + lines.joined(separator: ",\n") + "\n]\n"
}
