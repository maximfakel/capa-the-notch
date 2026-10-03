import CapacityNotchCore
import Foundation

private let now = Date(timeIntervalSince1970: 1_000_000)

private func window(
    id: String = "w",
    label: String = "5 hour",
    durationMinutes: Int? = 300,
    used: Double,
    resetsIn: TimeInterval?
) -> QuotaWindow {
    QuotaWindow(
        id: id,
        label: label,
        durationMinutes: durationMinutes,
        usedFraction: used,
        resetsAt: resetsIn.map { now.addingTimeInterval($0) }
    )
}

func theStateIsReadOffWhatIsLeft() throws {
    try expect(window(used: 0.0, resetsIn: 3600).pace == .sustainable, "100% left")
    try expect(window(used: 0.24, resetsIn: 3600).pace == .sustainable, "76% left")
    try expect(window(used: 0.31, resetsIn: 3600).pace == .sustainable, "69% left")
    try expect(window(used: 0.40, resetsIn: 3600).pace == .sustainable, "60% is the boundary, and belongs to the better state")
    try expect(window(used: 0.46, resetsIn: 3600).pace == .tightening, "54% left")
    try expect(window(used: 0.89, resetsIn: 3600).pace == .tightening, "11% left")
    try expect(window(used: 0.90, resetsIn: 3600).pace == .tightening, "10% is the boundary, and belongs to the better state")
    try expect(window(used: 0.96, resetsIn: 3600).pace == .unsustainable, "4% left")
    try expect(window(used: 1.0, resetsIn: 3600).pace == .unsustainable, "nothing left")
}

func theClockDoesNotChangeTheColour() throws {
    // The same eleven percent, two hours from reset and six days from it.
    let nearly = window(durationMinutes: 10_080, used: 0.89, resetsIn: 2 * 3600)
    let far = window(durationMinutes: 10_080, used: 0.89, resetsIn: 6 * 24 * 3600)

    try expect(
        nearly.pace == far.pace,
        "Eleven percent reads as eleven percent whatever the clock says"
    )
    try expect(
        window(durationMinutes: nil, used: 0.89, resetsIn: nil).pace == .tightening,
        "A window with no duration and no reset is read the same way as any other"
    )
}

func theHeadlineIsTheScarcestWindow() throws {
    let snapshot = CapacitySnapshot(
        provider: .codex,
        capturedAt: now,
        windows: [
            window(id: "five-hour", label: "5 hour", durationMinutes: 300,
                   used: 0.70, resetsIn: 240 * 60),
            window(id: "weekly", label: "Weekly", durationMinutes: 10_080,
                   used: 0.89, resetsIn: 20 * 60),
        ],
        connectionState: .fresh
    )

    try expect(
        snapshot.headlineWindow?.id == "weekly",
        "The strip shows the window with the least left, got \(snapshot.headlineWindow?.id ?? "nothing")"
    )
}

func theCountdownSaysHowLongInTheFewestWords() throws {
    func text(_ seconds: TimeInterval) -> String {
        ResetCountdown.text(until: now.addingTimeInterval(seconds), at: now)
    }

    try expect(text(2 * 3600 + 14 * 60) == "2h 14m", "got \(text(2 * 3600 + 14 * 60))")
    try expect(text(3 * 3600) == "3h", "A whole number of hours needs no minutes, got \(text(3 * 3600))")
    try expect(text(48 * 60) == "48m", "got \(text(48 * 60))")
    try expect(text(30) == "under a minute", "got \(text(30))")
    try expect(
        text(-60) == "moments",
        "A reset already due reads as `resets in moments`, not `resets in any moment`, got \(text(-60))"
    )
    try expect(text(50 * 3600) == "2d 2h", "got \(text(50 * 3600))")
}

/// Under a gauge there is room for one short thing: the time of day while the
/// reset is within a day, a countdown past that ("Limits — C · Gauges").
func aGaugeSaysWhenItResetsInOneShortThing() throws {
    func reset(_ seconds: TimeInterval?) -> GaugeReset {
        GaugeReset(resetsAt: seconds.map { now.addingTimeInterval($0) }, at: now)
    }

    try expect(reset(3 * 3600) == .at(now.addingTimeInterval(3 * 3600)), "Within the day, the time it comes back")
    try expect(reset(24 * 3600 - 60) == .at(now.addingTimeInterval(24 * 3600 - 60)), "Still the time, just under a day")
    try expect(reset(50 * 3600) == .in("2d 2h"), "Past a day, how long")
    try expect(reset(-60) == .in("moments"), "Already due")
    try expect(reset(nil) == .unknown, "Not reported")
}
