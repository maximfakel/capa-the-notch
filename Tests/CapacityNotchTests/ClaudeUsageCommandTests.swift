import CapacityNotchCore
import Foundation

private let readAt = Date(timeIntervalSince1970: 1_789_909_000)

/// What `claude /usage` printed on a real machine, verbatim.
private let realReport = """
You are currently using your subscription to power your Claude Code usage

Current session: 24% used · resets Sep 20 at 7pm (Europe/Moscow)
Current week (all models): 89% used · resets Sep 20 at 6pm (Europe/Moscow)

What's contributing to your limits usage?
Approximate, based on local sessions on this machine.

Last 24h · 825 requests · 3 sessions
  97% of your usage was at >150k context
"""

func theUsageReportBecomesQuotaWindows() throws {
    guard let reading = ClaudeUsageOutput.reading(from: realReport, capturedAt: readAt) else {
        throw TestFailure(description: "A real usage report should produce a reading")
    }

    try expect(
        reading.windows.map(\.id) == ["claude-five-hour", "claude-seven-day"],
        "The windows should carry the same ids the bridge publishes, got \(reading.windows.map(\.id))"
    )
    try expect(
        reading.windows[0].remainingPercentage == 76,
        "24% used is 76% of Capacity left, got \(reading.windows[0].remainingPercentage)"
    )
    try expect(
        reading.windows[1].remainingPercentage == 11,
        "89% used is 11% of Capacity left, got \(reading.windows[1].remainingPercentage)"
    )
    try expect(
        reading.capturedAt == readAt,
        "The reading is as old as the moment it was taken, not as old as the report says"
    )

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Europe/Moscow")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let reset = reading.windows[0].resetsAt.map(formatter.string(from:))
    try expect(
        reset == "2026-09-20 19:00",
        "`Sep 20 at 7pm (Europe/Moscow)` should read as that moment there, got \(reset ?? "nothing")"
    )
}

func proseThatNoLongerParsesIsNotAReading() throws {
    try expect(
        ClaudeUsageOutput.reading(from: "Session usage: 24 percent\n", capturedAt: readAt) == nil,
        "Wording CapaTheNotch does not know must produce nothing, never a guess"
    )
    try expect(
        ClaudeUsageOutput.reading(from: "", capturedAt: readAt) == nil,
        "Empty output is not a reading"
    )
    try expect(
        ClaudeUsageOutput.reading(
            from: "Current session: 24% used\n",
            capturedAt: readAt
        )?.windows.first?.resetsAt == nil,
        "A line with no reset time should still read, with the reset unknown"
    )
}

func aWindowInWordingNotKnownRefusesTheWholeReport() throws {
    let reworded = realReport.replacingOccurrences(
        of: "Current week (all models):",
        with: "This week (all models):"
    )

    try expect(
        ClaudeUsageOutput.reading(from: reworded, capturedAt: readAt) == nil,
        "A window CapaTheNotch cannot name means the report changed; showing the one it still knows would silently drop the other"
    )
}

func windowsLeftOutOnPurposeOrNotPrintedAreNotAChangedReport() throws {
    let withAModelWeek = realReport.replacingOccurrences(
        of: "Current week (all models): 89% used · resets Sep 20 at 6pm (Europe/Moscow)",
        with: """
        Current week (all models): 89% used · resets Sep 20 at 6pm (Europe/Moscow)
        Current week (Fable): 41% used · resets Sep 20 at 6pm (Europe/Moscow)
        """
    )
    try expect(
        ClaudeUsageOutput.reading(from: withAModelWeek, capturedAt: readAt)?.windows.map(\.id)
            == ["claude-five-hour", "claude-seven-day"],
        "A per-model week is left out knowingly, and must not read as a report CapaTheNotch no longer understands"
    )

    try expect(
        ClaudeUsageOutput.reading(
            from: "Current session: 24% used · resets Sep 20 at 7pm (Europe/Moscow)\n",
            capturedAt: readAt
        )?.windows.map(\.id) == ["claude-five-hour"],
        "A plan that prints no weekly window has one window, not a changed report"
    )
}

func aWindowWithoutAYearReadsAsTheOneAhead() throws {
    // Read on 28 December, a window that resets on 2 January.
    let december = Date(timeIntervalSince1970: 1_798_500_000)
    let window = ClaudeUsageOutput.reading(
        from: "Current session: 5% used · resets Jan 2 at 3am (UTC)\n",
        capturedAt: december
    )?.windows.first

    guard let resetsAt = window?.resetsAt else {
        throw TestFailure(description: "The reset should parse")
    }
    try expect(
        resetsAt > december,
        "A reset printed without a year belongs ahead of the reading, not a year behind it"
    )
    try expect(
        resetsAt.timeIntervalSince(december) < 40 * 24 * 60 * 60,
        "And it belongs just ahead, not eleven months ahead"
    )
}

private struct StubSource: ClaudeCapacitySource {
    let reading: ClaudeCapacityReading?
    let failure: Error?

    func read() throws -> ClaudeCapacityReading {
        if let reading { return reading }
        throw failure ?? ClaudeUsageCommandError.outputNotUnderstood
    }
}

private func stub(secondsAgo: TimeInterval, used: Double) -> StubSource {
    StubSource(
        reading: ClaudeCapacityReading(
            capturedAt: readAt.addingTimeInterval(-secondsAgo),
            windows: [
                QuotaWindow(
                    id: "claude-five-hour",
                    label: "5 hour",
                    durationMinutes: 300,
                    usedFraction: used,
                    resetsAt: nil
                ),
            ]
        ),
        failure: nil
    )
}

func theNewerOfTwoSourcesWins() throws {
    let newest = try NewestClaudeCapacity([
        stub(secondsAgo: 600, used: 0.10),
        stub(secondsAgo: 30, used: 0.40),
    ], now: { readAt }).read()

    try expect(
        newest.windows[0].remainingPercentage == 60,
        "The reading taken most recently should be the one shown, got \(newest.windows[0].remainingPercentage)"
    )

    let survivor = try NewestClaudeCapacity([
        StubSource(reading: nil, failure: ClaudeUsageCommandError.commandFailed),
        stub(secondsAgo: 30, used: 0.40),
    ], now: { readAt }).read()
    try expect(
        survivor.windows[0].remainingPercentage == 60,
        "One source failing should not cost the reading the other has"
    )

    do {
        _ = try NewestClaudeCapacity([
            StubSource(reading: nil, failure: ClaudeUsageCommandError.commandFailed),
        ], now: { readAt }).read()
        throw TestFailure(description: "With every source failing there is no reading to give")
    } catch is ClaudeUsageCommandError {
        // Expected.
    }
}

func aBridgeThatWasNeverSetUpDoesNotHideWhyUsageFailed() throws {
    let noBridge = StubSource(reading: nil, failure: ClaudeStatusLineBridgeError.missingSnapshot)

    do {
        _ = try NewestClaudeCapacity([
            noBridge,
            StubSource(reading: nil, failure: ClaudeUsageCommandError.outputNotUnderstood),
        ]).read()
        throw TestFailure(description: "With every source failing there is no reading to give")
    } catch let failure as ClaudeUsageCommandError {
        try expect(
            failure == .outputNotUnderstood,
            "The failure that says what to fix should surface, got \(failure)"
        )
    } catch {
        throw TestFailure(
            description: "A bridge nobody set up is an absence, not the failure; got \(error)"
        )
    }

    do {
        _ = try NewestClaudeCapacity([noBridge]).read()
        throw TestFailure(description: "With every source failing there is no reading to give")
    } catch ClaudeStatusLineBridgeError.missingSnapshot {
        // Expected: with nothing else to say, the absence is the answer.
    }
}

func aBrokenBridgeFileDoesNotHideWhyUsageFailed() throws {
    do {
        _ = try NewestClaudeCapacity([
            StubSource(reading: nil, failure: ClaudeStatusLineBridgeError.malformedInput),
            StubSource(reading: nil, failure: ClaudeUsageCommandError.commandFailed),
        ], now: { readAt }).read()
        throw TestFailure(description: "With every source failing there is no reading to give")
    } catch let failure as ClaudeUsageCommandError {
        try expect(failure == .commandFailed, "The /usage failure should surface, got \(failure)")
    } catch {
        throw TestFailure(
            description: "The bridge is the optional source; its broken file should not speak over /usage, got \(error)"
        )
    }
}

func anOldReadingDoesNotHideWhyTheOtherSourceFailed() throws {
    let failing = StubSource(reading: nil, failure: ClaudeUsageCommandError.commandFailed)

    do {
        _ = try NewestClaudeCapacity(
            [stub(secondsAgo: 86_400, used: 0.50), failing],
            now: { readAt }
        ).read()
        throw TestFailure(description: "A day-old reading should not stand in for a source that just failed")
    } catch let failure as ClaudeUsageCommandError {
        try expect(failure == .commandFailed, "The failure should surface, got \(failure)")
    }

    let fresh = try NewestClaudeCapacity(
        [stub(secondsAgo: 30, used: 0.40), failing],
        now: { readAt }
    ).read()
    try expect(
        fresh.windows[0].remainingPercentage == 60,
        "A fresh reading still wins over a failure"
    )

    let oldAndAlone = try NewestClaudeCapacity(
        [stub(secondsAgo: 86_400, used: 0.50), StubSource(reading: nil, failure: ClaudeStatusLineBridgeError.missingSnapshot)],
        now: { readAt }
    ).read()
    try expect(
        oldAndAlone.windows[0].remainingPercentage == 50,
        "With nothing telling to say instead, an old reading is still the last one seen"
    )
}

/// A stand-in for the `claude` binary: a real executable, so what is under
/// test is the waiting on a real process and the reading of its output.
private func fakeClaude(_ body: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("capacity-notch-fake-claude-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("claude")
    try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script.path
}

func aClaudeCodeThatHangsIsGivenUpOnAtTheTimeout() throws {
    let source = ClaudeUsageCommandSource(
        searchPaths: [try fakeClaude("sleep 8")],
        timeout: 1
    )

    let started = Date()
    do {
        _ = try source.read()
        throw TestFailure(description: "A Claude Code that never answers has no reading to give")
    } catch let failure as ClaudeUsageCommandError {
        try expect(failure == .commandFailed, "A run that timed out did not answer, got \(failure)")
    }
    let waited = Date().timeIntervalSince(started)

    try expect(
        waited < 4,
        "A one-second timeout should end the wait, not the process ending on its own; waited \(String(format: "%.1f", waited))s"
    )
}

func anAnswerBeforeTheTimeoutIsStillRead() throws {
    let report = "Current session: 24% used · resets Sep 20 at 7pm (Europe/Moscow)"
    let source = ClaudeUsageCommandSource(
        searchPaths: [try fakeClaude("sleep 0.3\necho '\(report)'")],
        timeout: 5
    )

    let reading = try source.read()
    try expect(
        reading.windows.map(\.id) == ["claude-five-hour"],
        "What Claude Code prints before the deadline is the reading"
    )
}

final class CountingSource: ClaudeCapacitySource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func read() throws -> ClaudeCapacityReading {
        lock.lock()
        count += 1
        lock.unlock()
        return ClaudeCapacityReading(capturedAt: readAt, windows: [])
    }
}

func askingClaudeCodeIsThrottled() throws {
    let counted = CountingSource()
    let clock = MutableClock(now: readAt)
    let throttled = ThrottledCapacitySource(counted, interval: 300, now: clock.read)

    _ = try throttled.read()
    _ = try throttled.read()
    clock.advance(by: 299)
    _ = try throttled.read()

    try expect(counted.reads == 1, "Inside the interval the held answer is reused, got \(counted.reads)")

    clock.advance(by: 2)
    _ = try throttled.read()
    try expect(counted.reads == 2, "Past the interval it asks again, got \(counted.reads)")
}

final class FailingCountingSource: ClaudeCapacitySource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }

    func read() throws -> ClaudeCapacityReading {
        lock.withLock { count += 1 }
        throw ClaudeUsageCommandError.commandFailed
    }
}

func aFailedAskIsHeldOnlyBrieflyNotForTheWholeInterval() throws {
    // After an update the first /usage can hang until its timeout; holding
    // that failure as long as an answer kept Claude unread for minutes.
    let failing = FailingCountingSource()
    let clock = MutableClock(now: readAt)
    let throttled = ThrottledCapacitySource(failing, interval: 300, now: clock.read)

    _ = try? throttled.read()
    clock.advance(by: 29)
    _ = try? throttled.read()
    try expect(failing.reads == 1, "A failure is held for a moment, got \(failing.reads) asks")

    clock.advance(by: 2)
    _ = try? throttled.read()
    try expect(failing.reads == 2, "Then asked again, not after five minutes; got \(failing.reads) asks")
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date) { current = now }

    var read: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}
