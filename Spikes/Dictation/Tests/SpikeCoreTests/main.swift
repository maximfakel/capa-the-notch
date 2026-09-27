import Foundation
import SpikeCore

struct Failure: Error, CustomStringConvertible { let description: String }

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure(description: message) }
}

// MARK: - Word error rate

func wordsAreComparedWithoutCaseOrPunctuation() throws {
    try expect(
        Transcript.words("Сделай, пожалуйста, Pull Request — в main!") == ["сделай", "пожалуйста", "pull", "request", "в", "main"],
        "Lowercase, no punctuation, dashes standing alone dropped: \(Transcript.words("Сделай, пожалуйста, Pull Request — в main!"))"
    )
    try expect(Transcript.words("Ёлка ёжик") == ["елка", "ежик"], "Ё counts as е, as people type it")
}

func theErrorRateCountsTheEditsBetweenReferenceAndRecognition() throws {
    let same = ErrorRate.words(reference: "открой pull request", hypothesis: "Открой pull request.")
    try expect(same.edits == 0 && same.rate == 0, "The same words, however written, are no errors")

    let one = ErrorRate.words(reference: "открой pull request в main", hypothesis: "открой пул реквест в main")
    try expect(one.substitutions == 2 && one.insertions == 0 && one.deletions == 0, "Two words replaced: \(one)")
    try expect(one.edits == 2 && abs(one.rate - 2.0 / 5) < 1e-9, "Two edits of five words")

    let missing = ErrorRate.words(reference: "запусти тесты сейчас", hypothesis: "запусти")
    try expect(missing.deletions == 2, "Words left out are deletions: \(missing)")
    let extra = ErrorRate.words(reference: "запусти", hypothesis: "запусти тесты")
    try expect(extra.insertions == 1, "Words added are insertions: \(extra)")
}

func characterErrorRateIgnoresSpaces() throws {
    let rate = ErrorRate.characters(reference: "swift ui", hypothesis: "SwiftUI")
    try expect(rate.edits == 0, "The same letters, spaced differently, are no errors: \(rate)")
}

// MARK: - English terms

func englishTermsAreCheckedForLatinSpelling() throws {
    let check = TermCheck.check(reference: "Открой pull request в SwiftUI", hypothesis: "открой пул реквест в SwiftUI")
    try expect(check.terms == ["pull", "request", "swiftui"], "The reference's Latin words are the terms: \(check.terms)")
    try expect(check.latin == ["swiftui"], "Only SwiftUI came out in Latin: \(check.latin)")
    try expect(abs(check.latinRate - 1.0 / 3) < 1e-9, "A third")

    let none = TermCheck.check(reference: "Добрый день", hypothesis: "Добрый день")
    try expect(none.terms.isEmpty && none.latinRate == 1, "No terms, nothing to miss")
}

// MARK: - The corpus

func theCorpusHasPhrasesOfEachLengthWithTerms() throws {
    let corpus = Corpus.phrases
    try expect(corpus.count >= 30, "About thirty phrases: \(corpus.count)")
    try expect(Set(corpus.map(\.id)).count == corpus.count, "Each with its own id")
    try expect(corpus.filter { !TermCheck.check(reference: $0.text, hypothesis: "").terms.isEmpty }.count >= corpus.count * 2 / 3, "Most carry English terms")
    for length in Corpus.Length.allCases {
        try expect(corpus.contains { $0.length == length }, "Some \(length) phrases")
    }
}

func aSummaryAddsUpThePhrases() throws {
    let summary = CorpusScore.summary([
        CorpusScore.Result(id: "a", reference: "открой pull request", hypothesis: "открой пул request", seconds: 3, decodeSeconds: 0.3),
        CorpusScore.Result(id: "b", reference: "запусти тесты", hypothesis: "запусти тесты", seconds: 2, decodeSeconds: 0.1),
    ])
    try expect(summary.words == 5 && summary.wordEdits == 1, "Five words, one edit: \(summary)")
    try expect(abs(summary.wordErrorRate - 0.2) < 1e-9, "20 %")
    try expect(summary.terms == 2 && summary.latinTerms == 1, "Two terms, one in Latin")
    try expect(abs(summary.realTimeFactor - 0.4 / 5) < 1e-9, "Decode time over audio time")
}

// MARK: -

let tests: [(String, () throws -> Void)] = [
    ("wordsAreComparedWithoutCaseOrPunctuation", wordsAreComparedWithoutCaseOrPunctuation),
    ("theErrorRateCountsTheEditsBetweenReferenceAndRecognition", theErrorRateCountsTheEditsBetweenReferenceAndRecognition),
    ("characterErrorRateIgnoresSpaces", characterErrorRateIgnoresSpaces),
    ("englishTermsAreCheckedForLatinSpelling", englishTermsAreCheckedForLatinSpelling),
    ("theCorpusHasPhrasesOfEachLengthWithTerms", theCorpusHasPhrasesOfEachLengthWithTerms),
    ("aSummaryAddsUpThePhrases", aSummaryAddsUpThePhrases),
]
var failed = 0
for (name, test) in tests {
    do { try test(); print("PASS \(name)") } catch { failed += 1; print("FAIL \(name): \(error)") }
}
exit(failed == 0 ? 0 : 1)
