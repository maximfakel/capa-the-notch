import CapacityNotchCore
import Foundation

private let start = Date(timeIntervalSince1970: 1_800_000_000)

/// 130 words in 13 lines: ten words a line, so at 130 words a minute the
/// Script moves on 13 lines a minute — one every 60/13 seconds.
private func playback(words: Int = 130, lines: Int = 13) -> TeleprompterPlayback {
    TeleprompterPlayback(wordCount: words, lineCount: lines)
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

// MARK: - The Script

func aScriptCountsItsWordsAcrossLinesAndSpaces() throws {
    try expect(TeleprompterScript.wordCount("") == 0, "Nothing is no words")
    try expect(TeleprompterScript.wordCount("  \n\n ") == 0, "Blank lines are no words")
    try expect(TeleprompterScript.wordCount("Добрый день.\nСегодня  я покажу") == 5, "Words, however they are spaced")
    try expect(TeleprompterScript.wordCount("Claude — и Codex") == 3, "A dash standing alone is not a word")
}

func aScriptTakesAMinuteAtLeastAndRoundsToTheNearest() throws {
    try expect(TeleprompterScript.minutes(words: 0, wordsPerMinute: 130) == 0, "Nothing takes no time")
    try expect(TeleprompterScript.minutes(words: 39, wordsPerMinute: 130) == 1, "A short Script is a minute")
    try expect(TeleprompterScript.minutes(words: 412, wordsPerMinute: 130) == 3, "412 words at 130 is about 3 minutes")
    try expect(TeleprompterScript.minutes(words: 412, wordsPerMinute: 260) == 2, "And about 2 at twice the speed")
}

func aScriptKeepsItsLineBreaksAndBlankLinesAndWrapsTheRest() throws {
    let wrapped = TeleprompterScript.lines("\n\n  First paragraph  \n\nSecond one\n\n") { paragraph in
        paragraph.count > 6 ? [String(paragraph.prefix(6)), String(paragraph.dropFirst(6))] : [paragraph]
    }
    try expect(wrapped == ["First ", "paragraph", "", "Second", " one"], "Got \(wrapped)")
    try expect(TeleprompterScript.lines(" \n \n") { [$0] }.isEmpty, "Blank is no lines")
}

func pastingReplacesTheScriptAndOnlyTheOneBeforeComesBack() throws {
    let preferences = Preferences(defaults: UserDefaults(suiteName: "teleprompter.\(UUID().uuidString)")!)
    try expect(preferences.script.isEmpty && preferences.previousScript == nil, "No Script until one is given")

    preferences.replaceScript(with: "first")
    preferences.replaceScript(with: "second")
    try expect(preferences.script == "second" && preferences.previousScript == "first", "A new Script keeps the one before")

    preferences.restorePreviousScript()
    try expect(preferences.script == "first", "Restore brings the one before back")
    try expect(preferences.previousScript == "second", "And keeps the one it replaced, so restoring twice undoes itself")

    preferences.replaceScript(with: "third")
    try expect(preferences.previousScript == "first", "Only one step is kept")

    preferences.replaceScript(with: "third")
    try expect(preferences.previousScript == "first", "Pasting the same Script again forgets nothing")
}

func theTeleprompterIsOffWithQuietDefaults() throws {
    let preferences = Preferences(defaults: UserDefaults(suiteName: "teleprompter.\(UUID().uuidString)")!)
    try expect(!preferences.teleprompterEnabled, "Off until turned on (ADR 0003)")
    try expect(preferences.teleprompterMultiplier == 1, "At 1.00x")
    preferences.teleprompterMultiplier = 5
    try expect(preferences.teleprompterMultiplier == TeleprompterPlayback.multipliers.upperBound, "The multiplier stays in range")
    try expect(preferences.teleprompterTextSize == .medium, "The mockup's size")
    try expect(
        preferences.teleprompterShortcut(for: .startOrPause) == TeleprompterShortcuts.standard[.startOrPause],
        "The shortcuts start as drawn"
    )


    let shortcut = KeyShortcut(keyCode: 35, modifiers: [.control, .command], keyLabel: "P")
    preferences.setTeleprompterShortcut(shortcut, for: .stop)
    try expect(preferences.teleprompterShortcut(for: .stop) == shortcut, "A shortcut set is remembered")
    try expect(shortcut.display == "⌃⌘P", "And spelled with the Mac's symbols")
}

// MARK: - Playback

func startingHoldsTheFirstLineThenMovesAtTheChosenSpeed() throws {
    var p = playback()
    try expect(p.state == .stopped && !p.isShowing, "Stopped shows no row")

    p.start(at: start)
    try expect(p.state == .running && p.isShowing, "Started, it runs")
    try expect(p.position(at: start.addingTimeInterval(0.9)) == 0, "The first line holds for about a second")
    try expect(
        near(p.position(at: start.addingTimeInterval(1 + 60 / 13.0)), 1),
        "Then one line every 60/13 s: \(p.position(at: start.addingTimeInterval(1 + 60 / 13.0)))"
    )
}

func anEmptyScriptDoesNotStart() throws {
    var p = playback(words: 0, lines: 0)
    p.start(at: start)
    try expect(p.state == .stopped, "Nothing to read, nothing runs")
}

func pauseHoldsThePlaceAndResumeGoesOnFromIt() throws {
    var p = playback()
    p.start(at: start)
    let later = start.addingTimeInterval(1 + 2 * 60 / 13.0)
    p.toggle(at: later)
    try expect(p.state == .paused, "Toggling a running Script pauses it")
    try expect(near(p.position(at: later.addingTimeInterval(30)), 2), "Paused, it stays where it was")

    let resumed = later.addingTimeInterval(30)
    p.toggle(at: resumed)
    try expect(p.state == .running, "Toggling again resumes")
    try expect(near(p.position(at: resumed.addingTimeInterval(60 / 13.0)), 3), "From where it was, without a second hold")
}

func stopClearsTheRowAndStartsOver() throws {
    var p = playback()
    p.start(at: start)
    p.stop()
    try expect(p.state == .stopped && !p.isShowing, "Stopped, no row")
    p.start(at: start.addingTimeInterval(100))
    try expect(p.position(at: start.addingTimeInterval(100.5)) == 0, "The next start is from the top")
}

func fasterAndSlowerChangeTheSpeedInQuarters() throws {
    var p = playback()
    try expect(near(p.multiplier, 1) && near(p.wordsPerMinute, 130), "1.00x is 130 words a minute")
    p.start(at: start)
    let later = start.addingTimeInterval(1 + 60 / 13.0)
    p.faster(at: later)
    try expect(near(p.multiplier, 1.25), "Faster is a quarter more: \(p.multiplier)")
    try expect(near(p.wordsPerMinute, 162.5), "Of 130: \(p.wordsPerMinute)")
    try expect(near(p.position(at: later), 1), "The place does not jump")
    try expect(near(p.position(at: later.addingTimeInterval(60 / (13 * 1.25))), 2), "And it goes on at the new speed")

    var slow = playback()
    for _ in 0 ..< 100 { slow.slower(at: start) }
    try expect(near(slow.multiplier, TeleprompterPlayback.multipliers.lowerBound), "Never slower than half")
    var quick = playback()
    for _ in 0 ..< 100 { quick.faster(at: start) }
    try expect(near(quick.multiplier, TeleprompterPlayback.multipliers.upperBound), "Never faster than twice")
    for _ in 0 ..< 3 { quick.slower(at: start) }
    try expect(near(quick.multiplier, 1.25), "Three quarters back from twice: \(quick.multiplier)")
}

func fingersMoveTheScriptAndPauseIt() throws {
    var p = playback()
    p.start(at: start)
    let later = start.addingTimeInterval(1 + 4 * 60 / 13.0)
    p.move(byLines: -1.5, at: later)
    try expect(p.state == .paused, "Moving it by hand pauses it")
    try expect(near(p.position(at: later), 2.5), "Back a line and a half")
    p.move(byLines: -10, at: later)
    try expect(p.position(at: later) == 0, "Never before the first line")
    p.move(byLines: 100, at: later)
    try expect(near(p.position(at: later), 12), "Nor past the last")
}

func draggingTheProgressGoesAnywhereInTheScript() throws {
    var p = playback()
    p.start(at: start)
    p.seek(toFraction: 0.5, at: start.addingTimeInterval(3))
    try expect(near(p.position(at: start.addingTimeInterval(3)), 6), "Half way is line six of twelve moves")
    try expect(p.state == .running, "A running Script keeps running from there")
    try expect(near(p.progress(at: start.addingTimeInterval(3)), 0.5), "And says so")
}

func draggingTheProgressOfAStoppedScriptChoosesWhereItStarts() throws {
    var p = playback()
    p.seek(toFraction: 0.5, at: start)
    try expect(p.state == .paused && p.isShowing, "Dragged, the row shows the place, paused")
    p.toggle(at: start.addingTimeInterval(1))
    try expect(p.state == .running, "Then it runs")
    try expect(near(p.position(at: start.addingTimeInterval(1 + 60 / 13.0)), 7), "From there, not from the top")
}

func atTheEndItStopsOnTheLastLineAndTheRowLeavesAfterThreeSeconds() throws {
    var p = playback()
    p.start(at: start)
    guard let end = p.endsAt else { throw TestFailure(description: "A running Script knows when it ends") }
    try expect(near(end.timeIntervalSince(start), 1 + 12 * 60 / 13.0), "Twelve moves after the hold")

    p.advance(to: end.addingTimeInterval(1))
    try expect(p.state == .finished && p.isShowing, "It stops on the last line and stays in view")
    try expect(near(p.position(at: end.addingTimeInterval(1)), 12), "On the last line")

    p.advance(to: end.addingTimeInterval(2.9))
    try expect(p.state == .finished, "Still there before three seconds")
    p.advance(to: end.addingTimeInterval(3))
    try expect(p.state == .stopped && !p.isShowing, "Gone after three seconds")

    p.toggle(at: end.addingTimeInterval(10))
    try expect(p.state == .running && p.position(at: end.addingTimeInterval(10.5)) == 0, "The next start is from the top")
}

func timeSpentAndLeftFollowThePlace() throws {
    var p = playback()
    p.start(at: start)
    let later = start.addingTimeInterval(1 + 3 * 60 / 13.0)
    try expect(near(p.elapsedSeconds(at: later), 3 * 60 / 13.0), "Time read so far")
    try expect(near(p.remainingSeconds(at: later), 9 * 60 / 13.0), "Time still to read")
    try expect(near(p.durationSeconds, 12 * 60 / 13.0), "And the whole, as the page shows it")
    p.faster(at: later)
    try expect(near(p.durationSeconds, 12 * 60 / (13 * 1.25)), "At the speed it is read at")
}

func aNewLayoutKeepsThePlaceInTheScript() throws {
    var p = playback()
    p.start(at: start)
    let later = start.addingTimeInterval(1 + 6 * 60 / 13.0)
    p.relayout(wordCount: 130, lineCount: 25, at: later)
    try expect(near(p.progress(at: later), 0.5), "Half way stays half way when the text grows: \(p.progress(at: later))")
}

// MARK: - The surface

func theTeleprompterRowTakesThePlaceOfTheMusicRow() throws {
    try expect(
        TeleprompterSurface.compactRow(teleprompterShowing: true, musicShown: true, fullscreen: false) == .teleprompter,
        "While it shows, music gives way"
    )
    try expect(
        TeleprompterSurface.compactRow(teleprompterShowing: true, musicShown: false, fullscreen: true) == .teleprompter,
        "It shows over a fullscreen application too"
    )
    try expect(
        TeleprompterSurface.compactRow(teleprompterShowing: false, musicShown: true, fullscreen: true) == .none,
        "Music still does not"
    )
    try expect(
        TeleprompterSurface.compactRow(teleprompterShowing: false, musicShown: true, fullscreen: false) == .music,
        "Stopped, music comes back"
    )
}

func whileItShowsTheSurfaceStaysOutOfCaptureAndHoverDoesNotOpenIt() throws {
    try expect(
        TeleprompterSurface.excludedFromCapture(sharingAllowed: true, teleprompterShowing: true),
        "Whatever the switch says, a Script on screen is not shared"
    )
    try expect(
        !TeleprompterSurface.excludedFromCapture(sharingAllowed: true, teleprompterShowing: false),
        "Stopped, the switch decides again"
    )
    try expect(TeleprompterSurface.excludedFromCapture(sharingAllowed: false, teleprompterShowing: false), "Off is off")
    try expect(!TeleprompterSurface.hoverOpens(teleprompter: .running), "Reading, a passing pointer does not open it")
    try expect(TeleprompterSurface.hoverOpens(teleprompter: .paused), "Paused, it does")
}

func pagesRunCapacityMusicTeleprompter() throws {
    let all = SurfacePageOrder.pages(musicLoaded: true, teleprompter: true)
    try expect(all == [.capacity, .music, .teleprompter], "In that order: \(all)")
    try expect(
        SurfacePageOrder.pages(musicLoaded: false, teleprompter: true) == [.capacity, .teleprompter],
        "Without a track, no music page"
    )
    try expect(SurfacePageOrder.pages(musicLoaded: false, teleprompter: false) == [.capacity], "Capacity alone")

    try expect(SurfacePageOrder.step(from: .capacity, by: 1, in: all) == .music, "Next")
    try expect(SurfacePageOrder.step(from: .teleprompter, by: 1, in: all) == .teleprompter, "The last page holds")
    try expect(SurfacePageOrder.step(from: .capacity, by: -1, in: all) == .capacity, "The first page holds")
    try expect(
        SurfacePageOrder.shown(.music, in: [.capacity, .teleprompter]) == .capacity,
        "A page that has gone falls back to Capacity"
    )
}

// MARK: - Diagnostics

func diagnosticsSayHowLongTheScriptIsAndNeverWhatItSays() throws {
    let script = "Добрый день. Сегодня я покажу секретный план"
    try expect(TeleprompterModule.observation(enabled: false, script: script) == "teleprompter-off", "Off, it says so")
    let said = TeleprompterModule.observation(enabled: true, script: script)
    try expect(said == "teleprompter-on-7-words", "On: that, and the length in words — got \(said)")

    let report = DiagnosticReport(
        applicationVersion: "0.1.5",
        systemVersion: "27.0",
        generatedAt: start,
        providers: [],
        observations: [said]
    ).text()
    for word in script.split(separator: " ") where word.count > 2 {
        try expect(!report.contains(word), "The report carries none of the Script's words, found \(word)")
    }
}
