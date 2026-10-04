import Foundation

/// One thing on the prompter at a time.
struct Card: Equatable {
    var section: String
    var text: String
    /// Prose is read word for word (the hook, a scripted CTA). Bullets are talked around.
    var prose: Bool

    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

struct Script: Equatable {
    var title: String
    var targetMinutes: Int
    var cards: [Card]

    static let empty = Script(title: "", targetMinutes: 15, cards: [])

    /// Seconds each card should take. Prose runs at about 150 words a minute;
    /// bullets share whatever time is left, with a 15 second floor.
    var budgets: [TimeInterval] {
        let proseSeconds = cards.filter(\.prose).reduce(0.0) { $0 + Double($1.words) / 2.5 }
        let bullets = cards.filter { !$0.prose }.count
        let left = Double(targetMinutes * 60) - proseSeconds
        let perBullet = bullets > 0 ? max(15, left / Double(bullets)) : 0
        return cards.map { $0.prose ? max(4, Double($0.words) / 2.5) : perBullet }
    }

    /// Reads markdown or plain text.
    ///   # Title                     the video title
    ///   Target: 15 min              the target length
    ///   ## Hook / **HOOK** / HOOK:  starts a section
    ///   - bullet                    one card each
    ///   plain paragraphs            word for word, split into short chunks
    static func parse(_ raw: String, fallbackTitle: String) -> Script {
        var title: String?
        var target: Int?
        var section = "Script"
        var cards: [Card] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            for chunk in chunks(paragraph.joined(separator: " ")) {
                cards.append(Card(section: section, text: chunk, prose: true))
            }
            paragraph = []
        }

        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush(); continue }
            if t.hasPrefix("---") || t.hasPrefix("```") { flush(); continue }

            if t.hasPrefix("# ") && title == nil && cards.isEmpty {
                flush(); title = clean(String(t.dropFirst(2))); continue
            }
            if t.hasPrefix("#") {
                flush(); section = clean(String(t.drop(while: { $0 == "#" }))); continue
            }
            if let minutes = targetMinutes(in: t) { target = minutes; continue }
            if let heading = boldHeading(t) { flush(); section = heading; continue }
            if let bullet = bulletText(t) {
                flush()
                let text = clean(bullet)
                if !text.isEmpty { cards.append(Card(section: section, text: text, prose: false)) }
                continue
            }
            paragraph.append(clean(t))
        }
        flush()

        return Script(title: title ?? fallbackTitle, targetMinutes: target ?? 15, cards: cards)
    }

    private static func targetMinutes(in line: String) -> Int? {
        let lower = line.lowercased()
        guard lower.hasPrefix("target") || lower.hasPrefix("length") || lower.hasPrefix("**target") else { return nil }
        guard lower.count < 40 else { return nil }
        let digits = lower.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
        return Int(digits).flatMap { $0 > 0 && $0 < 240 ? $0 : nil }
    }

    /// "**HOOK**", "HOOK:" or "Hook:" alone on a line.
    private static func boldHeading(_ line: String) -> String? {
        if line.hasPrefix("**") && line.hasSuffix("**") && line.count <= 48 {
            let inner = clean(line)
            return inner.isEmpty ? nil : inner.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        }
        if line.hasSuffix(":") && line.count <= 32 && !line.contains(".") {
            let words = line.split(separator: " ")
            if words.count <= 4 { return clean(String(line.dropLast())) }
        }
        return nil
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "• ", "+ ", "– "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 2 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return String(rest.dropFirst(2)) }
        }
        return nil
    }

    /// Strips inline markdown so the prompter shows only words.
    static func clean(_ s: String) -> String {
        var out = s
        if let regex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^)]*\\)") {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        }
        for token in ["**", "__", "`", "*"] { out = out.replacingOccurrences(of: token, with: "") }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Splits prose into chunks of about two sentences, never much past 28 words.
    static func chunks(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            let endsSentence = ".!?".contains(c) && (i + 1 == chars.count || chars[i + 1] == " ")
            if endsSentence {
                sentences.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current.trimmingCharacters(in: .whitespaces))
        }

        var out: [String] = []
        var bucket: [String] = []
        var count = 0
        for sentence in sentences {
            let n = sentence.split(separator: " ").count
            if !bucket.isEmpty && (count + n > 28 || bucket.count == 2) {
                out.append(bucket.joined(separator: " ")); bucket = []; count = 0
            }
            bucket.append(sentence); count += n
        }
        if !bucket.isEmpty { out.append(bucket.joined(separator: " ")) }
        return out
    }
}
