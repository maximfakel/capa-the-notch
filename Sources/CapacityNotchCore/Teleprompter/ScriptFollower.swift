import Foundation

/// One word of the Script as the row lays it out: what it says, folded the
/// way recognised speech is folded so the two compare, and where it stands —
/// its line and its characters in that line, for lighting it.
public struct ScriptWord: Equatable, Sendable {
    public let text: String
    public let line: Int
    /// UTF-16 range in the line's own text.
    public let range: NSRange

    public init(text: String, line: Int, range: NSRange) {
        self.text = text
        self.line = line
        self.range = range
    }
}

public enum ScriptWords {
    /// A word as both the Script and the recogniser are compared: lower case,
    /// ё as е, and only its letters and digits — punctuation, quotes, dashes
    /// and the recogniser's capitals fall away. Empty when nothing is left.
    public static func fold(_ word: some StringProtocol) -> String {
        String(word.lowercased().replacingOccurrences(of: "ё", with: "е").filter { $0.isLetter || $0.isNumber })
    }

    /// The Script's words, line by line, as `TeleprompterScript.wordCount`
    /// counts them: runs between spaces holding a letter or a digit.
    public static func words(lines: [String]) -> [ScriptWord] {
        var words: [ScriptWord] = []
        for (index, line) in lines.enumerated() {
            let text = line as NSString
            var location = 0
            for piece in line.split(whereSeparator: \.isWhitespace) {
                let range = text.range(of: String(piece), range: NSRange(location: location, length: text.length - location))
                guard range.location != NSNotFound else { continue }
                location = range.location + range.length
                let folded = fold(piece)
                guard !folded.isEmpty else { continue }
                words.append(ScriptWord(text: folded, line: index, range: range))
            }
        }
        return words
    }

    /// What the recogniser heard, as words to compare.
    public static func heard(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(fold).filter { !$0.isEmpty }
    }
}

/// Follows a reader through the Script by the words heard (ticket 20).
///
/// Every fifth of a second the recogniser hears the last few seconds again and
/// says what it heard; `hear` finds where in the Script those words were read
/// and moves the place to the last of them. This is matching against a text
/// already known, not open dictation, so it can be strict about what moves the
/// place:
///
/// - **Next words** move it on a single match; a few words further on need
///   two; a skipped line needs three in a row; anywhere else in the Script,
///   or back to where it has been, needs four.
/// - **Repeats and stumbles** ("я покажу, я покажу", "ка- как") are heard words
///   the alignment steps over; the place does not go back for them.
/// - **Off-script talk** matches nothing, so nothing moves.
/// - **Silence** hears nothing new, so nothing moves. The author's decision
///   (2026-10-07): the Script waits for the voice; it never falls back to the
///   set speed.
///
/// Pure and deterministic: no clock, no audio, nothing kept but the place.
public struct ScriptFollower: Equatable, Sendable {
    public let words: [ScriptWord]
    /// The word being said: the last one the voice was heard reading. Nil
    /// until the voice first reaches the Script.
    public private(set) var current: Int?

    /// At most this many of the newest words heard are compared: a few
    /// seconds of speech, which is all the window holds anyway.
    public static let wordsCompared = 12

    public init(words: [ScriptWord]) {
        self.words = words
    }

    public init(lines: [String]) {
        self.init(words: ScriptWords.words(lines: lines))
    }

    /// The line of the word being said.
    public var currentLine: Int? { current.map { words[$0].line } }

    /// Whether the voice has read the Script's last word.
    public var hasReachedEnd: Bool { current != nil && current == words.count - 1 }

    /// The place put by hand — two fingers on the row, the progress dragged:
    /// the voice is then expected at the start of that line.
    public mutating func expect(line: Int) {
        guard let first = words.firstIndex(where: { $0.line >= line }) else {
            current = words.isEmpty ? nil : words.count - 1
            return
        }
        current = first == 0 ? nil : first - 1
    }

    /// Whether the place is on this line, or just before its first word,
    /// where `expect(line:)` would put it.
    public func isOn(line: Int) -> Bool {
        if currentLine == line { return true }
        var expected = self
        expected.expect(line: line)
        return expected.current == current
    }

    /// Forgets the place: the next words heard are looked for from the top.
    public mutating func reset() { current = nil }

    /// One hearing of the last few seconds. Returns true when the place moved.
    @discardableResult
    public mutating func hear(_ heard: [String]) -> Bool {
        let heard = Array(heard.suffix(Self.wordsCompared))
        guard !heard.isEmpty, !words.isEmpty, let found = bestPlace(for: heard) else { return false }
        guard found != current else { return false }
        current = found
        return true
    }

    // MARK: - Matching

    /// Scores, in matched words.
    private static let exact = 1.0
    private static let close = 0.8
    /// The newest word heard is often cut off by the window's edge.
    private static let cutOff = 0.6
    /// A word of one or two letters ("и", "в", "на") says little on its own.
    private static let shortWeight = 0.5
    private static let skippedHeard = 0.4
    private static let skippedScript = 0.6

    /// Local alignment (Smith–Waterman) of the words heard against the whole
    /// Script; of every alignment that ends on a matched pair, the one that
    /// ends on the newest words heard, nearest the place, with enough
    /// evidence for how far it would move.
    private func bestPlace(for heard: [String]) -> Int? {
        let n = words.count
        let m = heard.count
        let place = current ?? -1
        // row[j]: best alignment of the heard words so far ending at Script
        // word j-1, gaps allowed; `previous` is the same for one heard word fewer.
        var previous = [Double](repeating: 0, count: n + 1)
        var row = previous
        // Whether that alignment ends on a matched pair.
        var previousMatched = [Bool](repeating: false, count: n + 1)
        var rowMatched = previousMatched
        var best: (value: Double, index: Int)?

        for i in 1 ... m {
            row[0] = 0
            rowMatched[0] = false
            let newest = i == m
            for j in 1 ... n {
                let pair = Self.similarity(heard: heard[i - 1], script: words[j - 1].text, newest: newest)
                var value = max(0, previous[j] - Self.skippedHeard, row[j - 1] - Self.skippedScript)
                rowMatched[j] = false
                if pair > 0 {
                    let matched = previous[j - 1] + pair
                    if matched >= value { value = matched; rowMatched[j] = true }
                    let index = j - 1
                    let distance = index - place
                    // Back only when the newest word heard is itself from
                    // earlier — a reader starting a sentence again — never
                    // because the newest word was not made out yet.
                    let backAllowed = distance >= 0 || newest
                    // "и", "в", "не" are everywhere: one is lit next to the
                    // place, or straight after the word before it was heard.
                    let shortAllowed = words[index].text.count > 2 || (0 ... 2).contains(distance) || previousMatched[j - 1]
                    if backAllowed, shortAllowed, matched >= Self.evidenceNeeded(distance: distance) {
                        // Newer heard words outrank older ones; then nearness to the place.
                        let recency = Double(m - i) * 2
                        let farness = distance >= 0 ? Double(distance) * 0.02 : Double(-distance) * 0.1
                        let rank = matched - recency - farness
                        if best == nil || rank > best!.value { best = (rank, index) }
                    }
                }
                row[j] = value
            }
            swap(&previous, &row)
            swap(&previousMatched, &rowMatched)
        }
        return best?.index
    }

    /// How much matching it takes to move the place this far.
    private static func evidenceNeeded(distance: Int) -> Double {
        switch distance {
        case 0: 0 // staying put needs nothing
        case 1 ... 2: 0.8
        case 3 ... 12: 1.6
        case 13 ... 40: 2.6
        default: 3.6 // far ahead, or back
        }
    }

    /// How well a heard word stands for a Script word, from 0 (not at all).
    private static func similarity(heard: String, script: String, newest: Bool) -> Double {
        let weight = script.count <= 2 ? shortWeight : 1
        if heard == script { return exact * weight }
        // Fuzzy only for words long enough to tell apart.
        guard script.count >= 4, heard.count >= 3 else { return 0 }
        if newest, heard.count < script.count, script.hasPrefix(heard) { return cutOff * weight }
        let distance = editDistance(Array(heard), Array(script))
        let ratio = 1 - Double(distance) / Double(max(heard.count, script.count))
        return ratio >= 0.7 ? close * weight : 0
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0 ... b.count)
        var row = previous
        for i in 1 ... a.count {
            row[0] = i
            for j in 1 ... max(b.count, 1) where !b.isEmpty {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &row)
        }
        return previous[b.count]
    }
}
