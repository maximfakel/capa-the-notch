import CapacityNotchCore
import Foundation

private let readAt = Date(timeIntervalSince1970: 1_700_000_000)

private func reading(_ provider: Provider) -> CapacitySnapshot {
    CapacitySnapshot(
        provider: provider,
        capturedAt: readAt,
        windows: [
            QuotaWindow(id: "week", label: "Weekly", durationMinutes: 10_080, usedFraction: 0.89, resetsAt: readAt),
            QuotaWindow(id: "five", label: "5 hour", durationMinutes: 300, usedFraction: 0.24, resetsAt: readAt),
        ],
        connectionState: .fresh
    )
}

func theStripShowsTheOnlyProvidersShortWindowLeftAndLongRight() throws {
    let sides = CompactStrip.sides([UnreadCapacity.snapshot(for: .codex), reading(.claudeCode)])
    guard case let .window(leftProvider, left)? = sides.left, case let .window(rightProvider, right)? = sides.right else {
        throw TestFailure(description: "One Provider on shows two of its windows, got \(sides)")
    }
    try expect(leftProvider == .claudeCode && rightProvider == .claudeCode, "Both are the Provider that is on")
    try expect(left.id == "five" && right.id == "week", "Five hours left, the week right")
}

func theStripShowsEachProvidersFiveHoursWhenBothAreOn() throws {
    let sides = CompactStrip.sides([reading(.codex), reading(.claudeCode)])
    guard case let .window(leftProvider, left)? = sides.left, case let .window(rightProvider, right)? = sides.right else {
        throw TestFailure(description: "Two Providers on show one window each, got \(sides)")
    }
    try expect(leftProvider == .codex && rightProvider == .claudeCode, "Codex left, Claude Code right")
    // The week has less left here, and still the five hours are shown.
    try expect(left.id == "five" && right.id == "five", "Each shows its five hours, got \(left.id) and \(right.id)")
    let unread = CompactStrip.sides([CapacitySnapshot(provider: .codex, capturedAt: readAt, windows: [], connectionState: .connecting), reading(.claudeCode)])
    guard case .provider? = unread.left else { throw TestFailure(description: "A Provider not read yet keeps its dash") }
}

func nothingConnectedLeavesTheStripEmpty() throws {
    let off = UnreadCapacity.snapshots(capturedAt: readAt)
    let sides = CompactStrip.sides(off)
    try expect(sides.left == nil && sides.right == nil, "Nothing on, nothing in the strip")
    try expect(SurfaceCards.nothingConnected(off), "Nothing on is nothing connected")
    try expect(!SurfaceCards.nothingConnected([UnreadCapacity.snapshot(for: .codex), reading(.claudeCode)]), "One on is not")
}

func theStripShowsTheWindowChosenInSettings() throws {
    let both = [reading(.codex), reading(.claudeCode)]
    func ids(_ choice: CompactWindowChoice) -> [String] {
        let sides = CompactStrip.sides(both, showing: choice)
        return [sides.left, sides.right].compactMap { side in
            if case let .window(_, window)? = side { return window.id }
            return nil
        }
    }
    // Weekly has 11% left against five hours' 76%: the choice, not the
    // Headline Window, decides.
    try expect(ids(.fiveHour) == ["five", "five"], "Five hours by default, though the week has less left")
    try expect(ids(.weekly) == ["week", "week"], "The week when asked")
    try expect(CompactWindowChoice.allCases == [.fiveHour, .weekly], "Two choices, as drawn: 5 часов and Неделя")

    // One Provider on shows both its windows, whatever is chosen.
    let alone = [UnreadCapacity.snapshot(for: .codex), reading(.claudeCode)]
    try expect(
        CompactStrip.sides(alone, showing: .weekly) == CompactStrip.sides(alone, showing: .fiveHour),
        "Alone, a Provider shows five hours and the week either way"
    )

    let suite = "compact-window-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try expect(Preferences(defaults: defaults).compactWindow == .fiveHour, "Five hours until chosen")
    Preferences(defaults: defaults).compactWindow = .weekly
    try expect(Preferences(defaults: defaults).compactWindow == .weekly, "The choice is kept")
    // "Least left" was a third choice until 2026-10-08.
    defaults.set("leastLeft", forKey: "compactWindow")
    try expect(Preferences(defaults: defaults).compactWindow == .fiveHour, "A choice no longer offered reads as five hours")
}

func theChosenWindowIsTheOneOfThatLengthNotTheShortestOrLongest() throws {
    // A Provider with an hour, five hours, a week and a month.
    let many = CapacitySnapshot(
        provider: .codex,
        capturedAt: readAt,
        windows: [
            QuotaWindow(id: "month", label: "Monthly", durationMinutes: 43_200, usedFraction: 0.1, resetsAt: readAt),
            QuotaWindow(id: "hour", label: "1 hour", durationMinutes: 60, usedFraction: 0.1, resetsAt: readAt),
            QuotaWindow(id: "week", label: "Weekly", durationMinutes: 10_080, usedFraction: 0.1, resetsAt: readAt),
            QuotaWindow(id: "five", label: "5 hour", durationMinutes: 300, usedFraction: 0.1, resetsAt: readAt),
        ],
        connectionState: .fresh
    )
    func left(_ snapshot: CapacitySnapshot, _ choice: CompactWindowChoice) -> String? {
        if case let .window(_, window)? = CompactStrip.sides([snapshot, reading(.claudeCode)], showing: choice).left { return window.id }
        return nil
    }
    try expect(left(many, .fiveHour) == "five", "Five hours is the five-hour window, not the hour")
    try expect(left(many, .weekly) == "week", "The week is the weekly window, not the month")
    // Without a window of that length, the nearest end stands in.
    let other = CapacitySnapshot(
        provider: .codex,
        capturedAt: readAt,
        windows: [
            QuotaWindow(id: "day", label: "Daily", durationMinutes: 1_440, usedFraction: 0.1, resetsAt: readAt),
            QuotaWindow(id: "month", label: "Monthly", durationMinutes: 43_200, usedFraction: 0.1, resetsAt: readAt),
        ],
        connectionState: .fresh
    )
    try expect(left(other, .fiveHour) == "day", "No five hours: the shortest")
    try expect(left(other, .weekly) == "month", "No week: the longest")
}

/// Providers stand in one order everywhere — Codex, Claude Code, then any
/// later one — whatever order their readings arrive in, so each keeps its
/// side of the strip and its place among the cards.
func providersStandInOneOrderWhateverOrderTheyArrive() throws {
    let sides = CompactStrip.sides([reading(.claudeCode), reading(.codex)])
    guard case let .window(left, _)? = sides.left, case let .window(right, _)? = sides.right else {
        throw TestFailure(description: "Two on, one window each, got \(sides)")
    }
    try expect(left == .codex && right == .claudeCode, "The first in order left, the second right")
    try expect(
        SurfaceCards.shown([reading(.claudeCode), reading(.codex)]).map(\.provider) == [.codex, .claudeCode],
        "The cards in the same order"
    )
    try expect(ProviderSelection.ordered([.claudeCode, .codex]) == [.codex, .claudeCode], "One order, from the Provider list")
}

/// At most two Providers can be on: the surface has two sides and room for
/// two cards. One already on can always stay on.
func atMostTwoProvidersCanBeOn() throws {
    try expect(ProviderSelection.visibleLimit == 2, "Two")
    try expect(ProviderSelection.canTurnOn(.claudeCode, alreadyOn: [.codex]), "A second joins the first")
    try expect(ProviderSelection.canTurnOn(.codex, alreadyOn: [.codex, .claudeCode]), "One already on stays on")
    // Only two Providers exist yet, so the refusal is seen with a limit of one.
    try expect(!ProviderSelection.canTurnOn(.claudeCode, alreadyOn: [.codex], limit: 1), "Past the limit, refused")
    try expect(
        ProviderSelection.toConnect([.claudeCode, .codex], limit: 1) == [.codex],
        "More chosen than allowed — a setting from elsewhere — connects the first in order only"
    )
}

/// One Provider on and not read yet: its dash stands on the left, where its
/// five hours will stand once read, whichever Provider it is.
func theOnlyProviderNotReadYetHasItsDashOnTheLeft() throws {
    let unread = CapacitySnapshot(provider: .claudeCode, capturedAt: readAt, windows: [], connectionState: .connecting)
    let sides = CompactStrip.sides([UnreadCapacity.snapshot(for: .codex), unread])
    guard case let .provider(left)? = sides.left else { throw TestFailure(description: "A dash on the left, got \(sides)") }
    try expect(left.provider == .claudeCode && sides.right == nil, "Claude Code's dash, and nothing on the right")
}

func claudeCodesFiveHoursNotSentShowAsADashInTheStrip() throws {
    let weekOnly = CapacitySnapshot(
        provider: .claudeCode,
        capturedAt: readAt,
        windows: [QuotaWindow(id: "claude-seven-day", label: "Weekly", durationMinutes: 10_080, usedFraction: 0.16, resetsAt: readAt)],
        connectionState: .fresh
    )
    let both = CompactStrip.sides([reading(.codex), weekOnly])
    try expect(both.right == .missing(.claudeCode), "Its five hours are not stood in for by its week, got \(String(describing: both.right))")
    guard case let .window(_, week)? = CompactStrip.sides([reading(.codex), weekOnly], showing: .weekly).right else {
        throw TestFailure(description: "Asked for the week, it shows the week")
    }
    try expect(week.id == "claude-seven-day", "the week it has")

    let alone = CompactStrip.sides([UnreadCapacity.snapshot(for: .codex), weekOnly])
    guard case .window(_, let right)? = alone.right else { throw TestFailure(description: "Alone, its week stays on the right, got \(alone)") }
    try expect(alone.left == .missing(.claudeCode) && right.id == "claude-seven-day", "and a dash where its five hours stand, got \(alone)")
}
