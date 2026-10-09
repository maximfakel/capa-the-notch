import CapacityNotchCore
import Foundation

// Ticket 20: the Teleprompter follows the voice. Each hearing is what the
// recogniser returns for the last few seconds, as words.

private let script = [
    "Добрый день. Сегодня я покажу, как CapaTheNotch",
    "держит лимиты Claude и Codex прямо у камеры,",
    "и почему это удобнее, чем вкладка со счётчиком,",
    "открытая весь день. Сначала — как выглядит полоса.",
    "Потом — что происходит, когда лимит подходит к концу.",
]

private func follower() -> ScriptFollower { ScriptFollower(lines: script) }

private func heard(_ text: String) -> [String] { ScriptWords.heard(text) }

/// The word the follower is on, as the Script spells it, folded.
private func word(_ f: ScriptFollower) -> String? { f.current.map { f.words[$0].text } }

func theScriptsWordsKnowTheirLineAndPlace() throws {
    let words = ScriptWords.words(lines: ["Сначала — как выглядит «полоса».", "", "Ёлка"])
    try expect(words.map(\.text) == ["сначала", "как", "выглядит", "полоса", "елка"], "A dash is no word; quotes and ё fold: \(words.map(\.text))")
    try expect(words[3].line == 0 && words[4].line == 2, "Each word knows its line")
    let line = "Сначала — как выглядит «полоса»." as NSString
    try expect(line.substring(with: words[3].range) == "«полоса».", "And its characters, to be lit: \(line.substring(with: words[3].range))")
    try expect(ScriptWords.heard("Добрый день, Codex!") == ["добрый", "день", "codex"], "The recogniser's punctuation and capitals fall away")
}

func followingMovesWithTheWordsReadInOrder() throws {
    var f = follower()
    try expect(f.current == nil && f.currentLine == nil, "Nothing is lit before the voice starts")
    f.hear(heard("Добрый"))
    try expect(word(f) == "добрый", "The first word lights on its own: \(word(f) ?? "nil")")
    f.hear(heard("Добрый день. Сегодня я"))
    try expect(word(f) == "я", "The place is the newest word heard: \(word(f) ?? "nil")")
    f.hear(heard("день. Сегодня я покажу, как Капа зе ноч держит"))
    try expect(word(f) == "держит", "A name misheard is stepped over: \(word(f) ?? "nil")")
    try expect(f.currentLine == 1, "And the line follows the word")
}

func aWordCutOffByTheWindowStillCounts() throws {
    var f = follower()
    f.hear(heard("Добрый день. Сегодня я пока"))
    try expect(word(f) == "покажу", "The newest word, half heard, is the next one: \(word(f) ?? "nil")")
}

func aRepeatOrAStumbleDoesNotMoveThePlaceBack() throws {
    var f = follower()
    f.hear(heard("Добрый день. Сегодня я покажу, как"))
    try expect(word(f) == "как", "Read up to как")
    f.hear(heard("Сегодня я покажу, как, я покажу, как"))
    try expect(word(f) == "как", "Saying it again keeps the place: \(word(f) ?? "nil")")
    f.hear(heard("я покажу, как ка- ка- как CapaTheNotch держит"))
    try expect(word(f) == "держит", "A stumble is stepped over: \(word(f) ?? "nil")")
}

func skippingALineJumpsAheadOnceTheVoiceIsSure() throws {
    var f = follower()
    f.hear(heard("Сегодня я покажу, как CapaTheNotch держит лимиты Claude"))
    try expect(f.currentLine == 1, "On the second line")
    // The third line is skipped: the reader goes on with the fourth.
    f.hear(heard("лимиты Claude и Codex прямо у камеры, открытая"))
    try expect(f.currentLine == 1, "One word from further on is not enough to jump: line \(f.currentLine ?? -1)")
    f.hear(heard("у камеры, открытая весь день. Сначала"))
    try expect(word(f) == "сначала" && f.currentLine == 3, "Three in a row from the next line but one jump there: \(word(f) ?? "nil")")
}

func talkOffTheScriptMovesNothing() throws {
    var f = follower()
    f.hear(heard("Добрый день. Сегодня я покажу"))
    let before = f.current
    for hearing in [
        "я покажу, секунду, сейчас открою окно",
        "сейчас открою окно, так, где же оно было",
        "где же оно было, ну ладно",
    ] {
        f.hear(heard(hearing))
        try expect(f.current == before, "“\(hearing)” is not the Script; the place holds at \(word(f) ?? "nil")")
    }
    f.hear(heard("ну ладно. как CapaTheNotch"))
    try expect(word(f) == "capathenotch", "Back on the Script, it goes on from where it was: \(word(f) ?? "nil")")
}

func whenTheVoiceStopsTheScriptHolds() throws {
    var f = follower()
    f.hear(heard("Добрый день. Сегодня я покажу"))
    let before = f
    // The window still holds the last words for a few seconds, then nothing.
    for hearing in ["Сегодня я покажу", "я покажу", "покажу", "", ""] {
        try expect(!f.hear(heard(hearing)), "“\(hearing)” moves nothing")
    }
    try expect(f == before, "Silence holds the place: the Script waits, never falls back to the set speed")
}

func aCommonShortWordAloneDoesNotJump() throws {
    var f = follower()
    f.hear(heard("Добрый день. Сегодня я покажу"))
    f.hear(heard("и"))
    try expect(word(f) == "покажу", "“и” stands in the Script further on, but alone it proves nothing: \(word(f) ?? "nil")")
    f.hear(heard("Сегодня я покажу и"))
    try expect(word(f) == "покажу", "Nor after the words just read, five words before the Script's “и”: \(word(f) ?? "nil")")
}

func aNewestWordNotYetMadeOutDoesNotPullThePlaceBack() throws {
    var f = follower()
    f.hear(heard("Добрый день. Сегодня я покажу, как"))
    try expect(word(f) == "как", "Read up to как")
    // The next hearing has lost "как" at the window's edge and has a fragment instead.
    f.hear(heard("Добрый день. Сегодня я покажу, ка"))
    try expect(word(f) == "как", "The place holds; it does not flick back to покажу: \(word(f) ?? "nil")")
}

func readingAgainFromEarlierGoesBackOnlyOnALongRun() throws {
    var f = follower()
    f.hear(heard("и почему это удобнее, чем вкладка со счётчиком"))
    try expect(f.currentLine == 2, "On the third line")
    f.hear(heard("держит"))
    try expect(f.currentLine == 2, "One earlier word does not pull it back")
    f.hear(heard("держит лимиты Claude и Codex"))
    try expect(word(f) == "codex" && f.currentLine == 1, "Re-reading a sentence does: \(word(f) ?? "nil")")
}

func theLastWordSaidIsTheEnd() throws {
    var f = follower()
    f.expect(line: 4)
    try expect(word(f) == "полоса", "Put on the last line by hand, the voice is expected at its start")
    f.hear(heard("Потом что происходит, когда лимит подходит к концу."))
    try expect(f.hasReachedEnd, "The last word said ends the Script")
    f.reset()
    try expect(f.current == nil, "Started over, it waits for the first words again")
}

// MARK: - The playback, following

private let now = Date(timeIntervalSince1970: 1_800_000_000)

func followingTheVoiceTheScriptMovesOnlyWhereTheVoiceIs() throws {
    var p = TeleprompterPlayback(wordCount: 130, lineCount: 13)
    p.setFollowsVoice(true, at: now)
    p.start(at: now)
    try expect(p.position(at: now.addingTimeInterval(60)) == 0, "Running and silent, the Script waits at the top")
    try expect(p.endsAt == nil, "Nothing is timed to end by itself")
    p.follow(toLine: 3, at: now.addingTimeInterval(10))
    try expect(p.position(at: now.addingTimeInterval(70)) == 3, "It goes to the voice's line and holds there")
    p.advance(to: now.addingTimeInterval(600))
    try expect(p.state == .running, "However long the voice is gone, it never falls back to the set speed")
    p.follow(toLine: 40, at: now)
    try expect(p.position(at: now) == 12, "A line past the end is the last")

    p.pause(at: now)
    p.follow(toLine: 5, at: now)
    try expect(p.position(at: now) == 12, "Paused, nothing is heard and nothing moves")
}

func theVoiceReadingTheLastWordFinishesTheScript() throws {
    var p = TeleprompterPlayback(wordCount: 130, lineCount: 13)
    p.setFollowsVoice(true, at: now)
    p.start(at: now)
    p.finishFollowing(at: now.addingTimeInterval(30))
    try expect(p.state == .finished && p.position(at: now.addingTimeInterval(31)) == 12, "Finished on the last line")
    p.advance(to: now.addingTimeInterval(33.1))
    try expect(p.state == .stopped, "And the row leaves three seconds later, as at the set speed")
}

func turningFollowingOffGoesOnAtTheSetSpeedFromThePlace() throws {
    var p = TeleprompterPlayback(wordCount: 130, lineCount: 13)
    p.setFollowsVoice(true, at: now)
    p.start(at: now)
    p.follow(toLine: 4, at: now.addingTimeInterval(5))
    p.setFollowsVoice(false, at: now.addingTimeInterval(20))
    let later = p.position(at: now.addingTimeInterval(20 + 60 / 13.0))
    try expect(abs(later - 5) < 0.0001, "From the voice's line, a line every 60/13 s: \(later)")
}
