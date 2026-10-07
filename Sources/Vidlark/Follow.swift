import Foundation

/// Moves the prompter on as the presenter speaks. Pure logic with no audio, so it can be run on a
/// transcript: `--test-follow <audio or .txt> <script.md>`.
///
/// Prose cards are read word for word. Her words are lined up against the card's in order,
/// allowing for changed, skipped and added words, and the card moves on once she reaches its end.
/// Bullet cards are talked around. The card moves on only when her recent words match the next
/// card (or the one after, for a skip) clearly better than the current one, and keep matching for
/// a moment. It never moves back, and it would rather miss a move than make a false one: the key
/// still works.
struct Follower {
    let cards: [Card]
    private(set) var index = 0
    /// Words of the current prose card she has already said, counted as the prompter shows them.
    private(set) var spoken = 0

    private let lines: [[Token]]
    private let stems: [Set<String>]
    private let weight: [String: Double]

    private var heard: [Token] = []
    private var total = 0
    private var start = 0
    private var shownAt = 0.0
    private var changedAt = 0.0
    private var loudAt = -Double.infinity
    private var endingSince: Double?
    private var leaning: (card: Int, since: Double)?
    private var carry: (card: Int, from: Int)?

    init(cards: [Card], title: String = "") {
        self.cards = cards
        lines = cards.map { card in
            card.text.split(whereSeparator: \.isWhitespace).enumerated().flatMap { i, word in
                Words.split(String(word)).map { Words.token($0, word: i) }
            }
        }
        stems = lines.map { Set($0.filter { !$0.stop }.map(\.stem)) }

        // A word on many cards says little about which card she is on. Title words come up all through a video.
        var count: [String: Int] = [:]
        for set in stems { for s in set { count[s, default: 0] += 1 } }
        let titled = Set(Words.split(title).map { Words.token($0) }.filter { !$0.stop }.map(\.stem))
        weight = count.reduce(into: [:]) { out, item in
            out[item.key] = (1 / Double(item.value)) * (titled.contains(item.key) ? 0.6 : 1)
        }
    }

    /// The prompter moved, by key or by voice. Only words heard after this count for the new card,
    /// except the opening words that moved it there.
    mutating func show(_ card: Int, at t: Double) {
        start = carry?.card == card ? min(carry?.from ?? total, total) : total
        carry = nil
        index = card
        spoken = 0
        heard = []
        shownAt = t
        changedAt = t
        endingSince = nil
        leaning = nil
    }

    /// Everything heard so far, the newest words still settling. `loudAt` is when the mic last
    /// heard her voice, so a recognizer that is slow to report is not taken for a pause.
    /// Returns the card to move to, or `cards.count` for the end of the script.
    mutating func hear(_ words: [String], at t: Double, loudAt: Double? = nil) -> Int? {
        if let loudAt { self.loudAt = loudAt }
        if words.count < start { start = words.count }
        total = words.count
        let fresh = words[start...].enumerated().flatMap { i, word in Words.split(word).map { Words.token($0, word: start + i) } }
        if fresh != heard {
            heard = fresh
            changedAt = t
        }
        return decide(at: t)
    }

    /// Time passing with nothing new heard, which is how a pause at the end of a card is noticed.
    mutating func tick(at t: Double, loudAt: Double? = nil) -> Int? {
        if let loudAt { self.loudAt = loudAt }
        return decide(at: t)
    }

    // MARK: Deciding

    private mutating func decide(at t: Double) -> Int? {
        guard cards.indices.contains(index) else { return nil }
        let line = lines[index]
        var loose = heard

        var ending: (lastWord: Bool, tail: Bool, most: Bool)?
        var pos = 0
        var after = total
        if cards[index].prose && !line.isEmpty {
            let a = Self.align(line, heard)
            pos = a.pos
            // Words after the last one the card explains may already belong to the next card.
            if let last = a.used.max(), last + 1 < heard.count { after = heard[last + 1].word }
            spoken = max(spoken, pos > 0 ? line[pos - 1].word + 1 : 0)
            // Words the card explains are not evidence for the next one.
            loose = heard.indices.filter { !a.used.contains($0) }.map { heard[$0] }

            // The last few real words, from the final stretch of the card only, so a short card's
            // opening words never count as its end.
            let content = line.indices.filter { !line[$0].stop }
            let late = content.filter { Double($0) >= 0.6 * Double(line.count) }
            let tail = late.isEmpty ? content.suffix(1) : late.suffix(3)
            let tailHits = tail.filter { a.hit[$0] }.count
            let lastWord = a.hit[line.count - 1] || (content.last.map { a.hit[$0] && pos > $0 } ?? false)
            let tailDone = tail.isEmpty ? pos >= line.count : tailHits >= min(2, tail.count)
            let hits = a.hit.filter { $0 }.count
            let most = Double(pos) >= 0.85 * Double(line.count) && Double(hits) >= 0.5 * Double(pos)
            if lastWord || tailDone || most { ending = (lastWord, tailDone, most) }
        }

        // Nothing points past this card until most of it is read, or it has had time to be read if
        // she lost her place. A bullet gets a few seconds.
        let words = Double(max(1, cards[index].words))
        let settled = cards[index].prose && !line.isEmpty
            ? Double(pos) >= 0.6 * Double(line.count) || t - shownAt >= words * 0.4 + 2
            : t - shownAt >= 3

        // She has started reading the next prose card: move at once, taking her first words along.
        if settled {
            let window = Array(loose.suffix(10))
            for k in [index + 1, index + 2] where cards.indices.contains(k) && cards[k].prose {
                let a = Self.align(Array(lines[k].prefix(12)), window, opening: true)
                let hits = a.hit.filter { $0 }.count
                let content = a.hit.indices.filter { a.hit[$0] && !lines[k][$0].stop }.count
                if k == index + 1 ? (hits >= 4 && content >= 2) : (hits >= 5 && content >= 3) {
                    if let first = a.used.min() { carry = (k, window[first].word) }
                    return k
                }
            }
        }

        // The end of a prose card, with a short grace so she is not cut off mid word.
        if let ending {
            let since = endingSince ?? t
            endingSince = since
            let quiet = t - max(changedAt, loudAt)
            let left = Double(line.count - pos)
            if (ending.lastWord && t - since >= 0.3)
                || (ending.tail && (quiet >= 0.5 || t - since >= 1.6))
                || (ending.most && (quiet >= 0.9 || t - since >= left * 0.4 + 1)) {
                carry = (index + 1, after)
                return index + 1
            }
        } else {
            endingSince = nil
        }

        // Talking around a bullet: her recent words have to point at a later card.
        guard settled, let k = bulletMatch(loose) else { leaning = nil; return nil }
        if leaning?.card != k { leaning = (k, t) }
        if let leaning, t - leaning.since >= 0.8 { return k }
        return nil
    }

    /// The next bullet card her recent words clearly belong to, or nil.
    private func bulletMatch(_ said: [Token]) -> Int? {
        let recent = said.filter { !$0.stop }.suffix(10).map(\.stem)
        guard recent.count >= 3 else { return nil }
        let latest = recent.suffix(6)
        func found(_ set: Set<String>, in words: some Collection<String>) -> Set<String> {
            set.filter { s in words.contains { Words.same($0, s) } }
        }
        func score(_ set: Set<String>) -> Double { set.reduce(0) { $0 + (weight[$1] ?? 1) } }

        let here = score(found(stems[index], in: recent))
        var beaten = here
        for k in [index + 1, index + 2] where cards.indices.contains(k) {
            // Only words that are not also on the cards she is skipping past tell them apart.
            var own = stems[k].subtracting(stems[index])
            if k == index + 2 { own.subtract(stems[index + 1]) }
            let base = min(3, max(2, Int((Double(own.count) * 0.6).rounded(.up))))
            let need = k == index + 1 ? base : base + 1
            let hits = found(own, in: recent)
            let s = score(hits)
            if !cards[k].prose, hits.count >= need, s >= 0.7 * Double(need), s >= beaten + 0.5,
               !found(hits, in: latest).isEmpty {
                return k
            }
            beaten = max(beaten, s)
        }
        return nil
    }

    /// Lines her words up against a card's, in order, stepping over card words she left out and
    /// words of her own. Returns how far through the card she is, which card words she said and
    /// which of her words were used. An opening match has to begin in the card's first five words.
    static func align(_ line: [Token], _ said: [Token], opening: Bool = false) -> (pos: Int, hit: [Bool], used: Set<Int>) {
        var pos = 0
        var hit = Array(repeating: false, count: line.count)
        var used = Set<Int>()
        for (i, w) in said.enumerated() {
            guard pos < line.count else { break }
            let reach = min(line.count - 1, pos + (opening && used.isEmpty ? 4 : 6))
            for j in pos...reach {
                let c = line[j]
                let jump = j - pos
                // Small words only count right where she is, and long jumps need a real word.
                if (c.stop || w.stop) && jump > 1 { continue }
                if jump > 3 && c.stem.count < 4 { continue }
                guard Words.same(w.stem, c.stem, loose: !c.stop && !w.stop) else { continue }
                hit[j] = true
                used.insert(i)
                pos = j + 1
                break
            }
        }
        return (pos, hit, used)
    }
}

/// One word as the follower compares it.
struct Token: Equatable {
    var stem: String
    var stop: Bool
    /// Which word it came from: of the card text as the prompter splits it, or of everything heard.
    var word = 0
}

enum Words {
    /// Lowercase words without punctuation, with number words as digits.
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if ch == "'" || ch == "\u{2019}" {
                continue
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.map { numbers[$0] ?? $0 }
    }

    static func token(_ word: String, word index: Int = 0) -> Token {
        let single = word.count == 1 && word.first?.isNumber == true
        return Token(stem: stem(word), stop: stop.contains(word) || single, word: index)
    }

    /// A light stemmer: enough to match "fees" to "fee", "hides" to "hiding", "anonymised" to "anonymized".
    static func stem(_ word: String) -> String {
        var s = word
        guard s.count > 3 else { return s }
        for (british, american) in [("isation", "ization"), ("ising", "izing"), ("ised", "ized"), ("ise", "ize"), ("our", "or")]
        where s.hasSuffix(british) && s.count > british.count + 2 {
            s = String(s.dropLast(british.count)) + american
            break
        }
        if s.hasSuffix("ies") && s.count > 4 {
            s = String(s.dropLast(3)) + "y"
        } else if s.hasSuffix("s") && !s.hasSuffix("ss") && !s.hasSuffix("us") && !s.hasSuffix("is") {
            s.removeLast()
        }
        if s.hasSuffix("ing") && s.count > 5 {
            s.removeLast(3)
        } else if s.hasSuffix("ed") && s.count > 4 {
            s.removeLast(2)
        } else if s.hasSuffix("ly") && s.count > 4 {
            s.removeLast(2)
        }
        if s.hasSuffix("e") && s.count > 3 { s.removeLast() }
        if s.count > 4, let last = s.last, s.dropLast().last == last, !"lsz".contains(last), !"aeiou".contains(last) {
            s.removeLast()
        }
        if s.hasSuffix("y") && s.count > 3 { s = String(s.dropLast()) + "i" }
        return s
    }

    /// Close enough to be the same word, allowing for a misheard letter. Loose also lets short
    /// words differ by one and sound-alikes match ("cellar" for "seller"), which suits reading
    /// along a card but not guessing a topic.
    static func same(_ a: String, _ b: String, loose: Bool = false) -> Bool {
        if a == b { return true }
        let shorter = min(a.count, b.count)
        if loose && shorter >= 4 && sound(a) == sound(b) { return true }
        if shorter >= 5 && zip(a, b).prefix(while: { $0 == $1 }).count >= 5 { return true }
        if shorter >= 7 { return distance(a, b) <= 2 }
        if shorter >= (loose ? 3 : 5) { return distance(a, b) <= 1 }
        return false
    }

    /// A rough sound of a word: soft c as s, ph as f, doubled letters once, inner vowels alike.
    static func sound(_ word: String) -> String {
        var s = word.replacingOccurrences(of: "ph", with: "f").replacingOccurrences(of: "ck", with: "k")
        for soft in ["ce", "ci", "cy"] { s = s.replacingOccurrences(of: soft, with: "s" + soft.dropFirst()) }
        var out = ""
        for (i, ch) in s.enumerated() {
            let c: Character = i > 0 && "aeiouy".contains(ch) ? "a" : ch
            if out.last != c { out.append(c) }
        }
        return out
    }

    /// Edit distance, giving up early past 2.
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 2 { return 3 }
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var next = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            if (next.min() ?? 0) > 2 { return 3 }
            row = next
        }
        return row[y.count]
    }

    static let numbers: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
        "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
        "hundred": "100", "thousand": "1000",
    ]

    /// Words that say nothing about which card she is on, fillers included.
    static let stop: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "so", "as", "at", "by", "for", "from", "in", "into", "of", "on",
        "onto", "to", "with", "without", "about", "over", "under", "up", "down", "out", "off", "than", "then", "that",
        "this", "these", "those", "there", "here", "it", "its", "itself", "is", "are", "was", "were", "be", "been",
        "being", "am", "i", "im", "me", "my", "mine", "we", "us", "our", "ours", "you", "your", "yours", "youre",
        "he", "him", "his", "she", "her", "hers", "they", "them", "their", "theirs", "theyre", "what", "which", "who",
        "whom", "whose", "when", "where", "why", "how", "all", "any", "both", "each", "every", "few", "more", "most",
        "much", "many", "some", "such", "no", "not", "nor", "only", "own", "same", "too", "very", "can", "cant",
        "could", "couldnt", "will", "wont", "would", "wouldnt", "should", "shouldnt", "shall", "may", "might", "must",
        "do", "does", "did", "doesnt", "dont", "didnt", "done", "doing", "have", "has", "had", "havent", "hasnt",
        "having", "just", "also", "still", "even", "ever", "never", "again", "really", "actually", "basically",
        "honestly", "literally", "like", "okay", "ok", "yeah", "yes", "um", "uh", "er", "ah", "oh", "well", "now",
        "right", "let", "lets", "ill", "ive", "id", "thats", "whats", "theres", "heres", "get", "gets", "got",
        "getting", "go", "goes", "going", "gonna", "went", "gone", "make", "makes", "made", "say", "says", "said",
        "see", "know", "mean", "thing", "things", "stuff", "lot", "lots", "way", "kind", "sort", "next", "first",
        "want", "need", "because", "while", "through", "after", "before", "until", "between", "during", "around",
        "once", "whether", "though", "although", "since", "yet", "else", "other", "another", "something",
        "anything", "everything", "nothing", "someone", "anyone", "everyone", "maybe", "probably", "quite",
        "pretty", "enough", "little", "bit", "ones", "via",
    ]
}
