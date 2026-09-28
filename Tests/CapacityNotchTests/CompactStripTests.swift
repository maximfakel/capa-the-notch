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

func nothingConnectedLeavesTheStripEmptyAndTheSurfaceOpen() throws {
    let off = UnreadCapacity.snapshots(capturedAt: readAt)
    let sides = CompactStrip.sides(off)
    try expect(sides.left == nil && sides.right == nil, "Nothing on, nothing in the strip")
    try expect(SurfaceCards.nothingConnected(off), "Nothing on keeps the surface open")
    try expect(!SurfaceCards.nothingConnected([UnreadCapacity.snapshot(for: .codex), reading(.claudeCode)]), "One on lets it close")
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
    try expect(ids(.fiveHour) == ["five", "five"], "Five hours by default")
    try expect(ids(.weekly) == ["week", "week"], "The week when asked")
    // Weekly has 11% left against five hours' 76%.
    try expect(ids(.leastLeft) == ["week", "week"], "The one with least left when asked")
    let suite = "compact-window-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try expect(Preferences(defaults: defaults).compactWindow == .fiveHour, "Five hours until chosen")
    Preferences(defaults: defaults).compactWindow = .weekly
    try expect(Preferences(defaults: defaults).compactWindow == .weekly, "The choice is kept")
}
