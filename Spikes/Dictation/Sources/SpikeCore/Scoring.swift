import Foundation

/// A transcript as the scores read it: words, lowercased, without
/// punctuation, ё as е. Recognition that differs only in how it is written is
/// not an error.
public enum Transcript {
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// How many edits turn the reference into what was recognised — the standard
/// word and character error rates, and the correction effort ticket 12 asks
/// for, which is the same count.
public enum ErrorRate {
    public struct Count: Equatable, Sendable, CustomStringConvertible {
        public let substitutions: Int
        public let deletions: Int
        public let insertions: Int
        public let length: Int

        public var edits: Int { substitutions + deletions + insertions }
        public var rate: Double { length > 0 ? Double(edits) / Double(length) : 0 }
        public var description: String { "S\(substitutions) D\(deletions) I\(insertions) of \(length)" }
    }

    public static func words(reference: String, hypothesis: String) -> Count {
        align(Transcript.words(reference), Transcript.words(hypothesis))
    }

    /// Letters and digits only, so spacing — "swift ui", "SwiftUI" — is not
    /// counted against the recognition.
    public static func characters(reference: String, hypothesis: String) -> Count {
        align(
            Array(Transcript.words(reference).joined()).map(String.init),
            Array(Transcript.words(hypothesis).joined()).map(String.init)
        )
    }

    /// Levenshtein, keeping which kind each edit was.
    static func align(_ reference: [String], _ hypothesis: [String]) -> Count {
        struct Cell { var cost = 0, s = 0, d = 0, i = 0 }
        var previous = (0 ... hypothesis.count).map { Cell(cost: $0, i: $0) }
        for (r, word) in reference.enumerated() {
            var current = [Cell(cost: r + 1, d: r + 1)]
            for (h, candidate) in hypothesis.enumerated() {
                let diagonal = previous[h]
                let same = word == candidate
                var best = diagonal
                best.cost += same ? 0 : 1
                if !same { best.s += 1 }
                var deletion = previous[h + 1]
                deletion.cost += 1
                deletion.d += 1
                var insertion = current[h]
                insertion.cost += 1
                insertion.i += 1
                for option in [deletion, insertion] where option.cost < best.cost { best = option }
                current.append(best)
            }
            previous = current
        }
        let last = previous[hypothesis.count]
        return Count(substitutions: last.s, deletions: last.d, insertions: last.i, length: reference.count)
    }
}

/// The English words in a reference, and which of them came back in Latin
/// letters. A Russian model may write "пул реквест" for "pull request"; that
/// is a correction the person has to make, and ticket 12 wants it counted.
public enum TermCheck {
    public struct Result: Equatable, Sendable {
        public let terms: [String]
        public let latin: [String]
        public var latinRate: Double { terms.isEmpty ? 1 : Double(latin.count) / Double(terms.count) }
    }

    public static func check(reference: String, hypothesis: String) -> Result {
        let terms = Transcript.words(reference).filter(isLatin)
        var recognised = Transcript.words(hypothesis).filter(isLatin)
        var latin: [String] = []
        for term in terms {
            if let index = recognised.firstIndex(of: term) {
                latin.append(term)
                recognised.remove(at: index)
            }
        }
        return Result(terms: terms, latin: latin)
    }

    static func isLatin(_ word: String) -> Bool {
        word.unicodeScalars.contains { ("a" ... "z").contains($0) }
    }
}

/// What a scored corpus adds up to.
public enum CorpusScore {
    public struct Result: Sendable {
        public let id: String
        public let reference: String
        public let hypothesis: String
        /// The recording's length.
        public let seconds: Double
        /// How long recognition took.
        public let decodeSeconds: Double

        public init(id: String, reference: String, hypothesis: String, seconds: Double, decodeSeconds: Double) {
            self.id = id
            self.reference = reference
            self.hypothesis = hypothesis
            self.seconds = seconds
            self.decodeSeconds = decodeSeconds
        }
    }

    public struct Summary: Sendable, CustomStringConvertible {
        public let phrases: Int
        public let words: Int
        public let wordEdits: Int
        public let characters: Int
        public let characterEdits: Int
        public let terms: Int
        public let latinTerms: Int
        public let audioSeconds: Double
        public let decodeSeconds: Double

        public var wordErrorRate: Double { words > 0 ? Double(wordEdits) / Double(words) : 0 }
        public var characterErrorRate: Double { characters > 0 ? Double(characterEdits) / Double(characters) : 0 }
        public var realTimeFactor: Double { audioSeconds > 0 ? decodeSeconds / audioSeconds : 0 }
        public var description: String {
            String(
                format: "%d phrases, WER %.1f%% (%d edits / %d words), CER %.1f%%, English terms in Latin %d/%d, RTF %.3f",
                phrases, wordErrorRate * 100, wordEdits, words, characterErrorRate * 100, latinTerms, terms, realTimeFactor
            )
        }
    }

    public static func summary(_ results: [Result]) -> Summary {
        let words = results.map { ErrorRate.words(reference: $0.reference, hypothesis: $0.hypothesis) }
        let characters = results.map { ErrorRate.characters(reference: $0.reference, hypothesis: $0.hypothesis) }
        let terms = results.map { TermCheck.check(reference: $0.reference, hypothesis: $0.hypothesis) }
        return Summary(
            phrases: results.count,
            words: words.map(\.length).reduce(0, +),
            wordEdits: words.map(\.edits).reduce(0, +),
            characters: characters.map(\.length).reduce(0, +),
            characterEdits: characters.map(\.edits).reduce(0, +),
            terms: terms.map(\.terms.count).reduce(0, +),
            latinTerms: terms.map(\.latin.count).reduce(0, +),
            audioSeconds: results.map(\.seconds).reduce(0, +),
            decodeSeconds: results.map(\.decodeSeconds).reduce(0, +)
        )
    }
}
