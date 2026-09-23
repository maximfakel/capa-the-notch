import CapacityNotchCore
import Foundation

private let spokenAt = Date(timeIntervalSince1970: 1_700_000_000)

private func utcClock() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "HH:mm"
    return formatter
}

private let fiveHour = QuotaWindow(
    id: "codex-primary",
    label: "5 hour",
    durationMinutes: 300,
    usedFraction: 0.96,
    resetsAt: spokenAt.addingTimeInterval(2160)
)

func aWindowSaysEverythingTheCardShows() throws {
    let said = CapacitySpeech.window(fiveHour, at: spokenAt, formatter: utcClock())

    for expected in ["5 hour window", "4 percent left", "running out", "96 percent used", "resets in 36m"] {
        try expect(said.contains(expected), "It should say \"\(expected)\", said: \(said)")
    }
}

func aWindowWithNoResetSaysSoRatherThanInventingOne() throws {
    let unknown = QuotaWindow(
        id: "w", label: "Weekly", durationMinutes: nil, usedFraction: 0.2, resetsAt: nil
    )
    let said = CapacitySpeech.window(unknown, at: spokenAt)

    try expect(
        said.contains("reset time not reported"),
        "An unknown reset is said aloud, not skipped, said: \(said)"
    )
}

func aProviderSaysWhoItIsAndHowItsReadingStands() throws {
    let fresh = CapacitySnapshot(
        provider: .codex,
        capturedAt: spokenAt,
        windows: [fiveHour],
        connectionState: .fresh
    )
    let said = CapacitySpeech.provider(fresh, at: spokenAt)

    try expect(said.hasPrefix("Codex. Fresh Capacity"), "It leads with who and how, said: \(said)")
    try expect(said.contains("5 hour window"), "And then the windows")
}

func anUnreadableProviderSaysTheOneThingThatWouldFixIt() throws {
    let stuck = CapacitySnapshot.disconnected(
        provider: .codex,
        capturedAt: spokenAt,
        reason: .providerNotInstalled
    )
    let said = CapacitySpeech.provider(stuck, at: spokenAt)

    try expect(said.contains("disconnected"), "It says the state, said: \(said)")
    try expect(
        said.contains("Install the Codex CLI"),
        "And the action, because a state with no action is no help, said: \(said)"
    )
}

func theClosedStripSaysTheWindowItIsShowing() throws {
    let snapshot = CapacitySnapshot(
        provider: .claudeCode,
        capturedAt: spokenAt,
        windows: [
            fiveHour,
            QuotaWindow(id: "w", label: "Weekly", durationMinutes: 10_080,
                        usedFraction: 0.1, resetsAt: spokenAt.addingTimeInterval(86_400)),
        ],
        connectionState: .fresh
    )
    let said = CapacitySpeech.compact(snapshot, at: spokenAt)

    try expect(
        said == "Claude Code, 5 hour window, 4 percent left, running out",
        "The strip names which window its figure belongs to, said: \(said)"
    )
}

func theStatesAreTellableApartWithoutColour() throws {
    try expect(
        CapacityPace.sustainable.spoken != CapacityPace.tightening.spoken,
        "Each state has its own words"
    )
    // What tells the states apart on screen is the figure, not the colour and
    // not a word: Capacity Pace is read off the remainder, so a row showing
    // 4% and a row showing 69% are already distinct to anyone who can read
    // either of them.
    let scarce = QuotaWindow(id: "a", label: "5 hour", durationMinutes: 300,
                             usedFraction: 0.96, resetsAt: nil)
    let ample = QuotaWindow(id: "b", label: "5 hour", durationMinutes: 300,
                            usedFraction: 0.31, resetsAt: nil)
    try expect(
        scarce.pace != ample.pace,
        "Two states"
    )
    try expect(
        scarce.remainingPercentage != ample.remainingPercentage,
        "And two figures, which is the distinction a colourblind reader makes"
    )
    try expect(
        CapacityConnectionState.stale.spoken != CapacityConnectionState.fresh.spoken,
        "And so does each connection state"
    )
}
