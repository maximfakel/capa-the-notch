import CapacityNotchCore
import Foundation

private let now = Date(timeIntervalSince1970: 2_000_000)

private func read(_ provider: Provider) -> CapacitySnapshot {
    CapacitySnapshot(
        provider: provider,
        capturedAt: now,
        windows: [QuotaWindow(id: "five", label: "5 hour", durationMinutes: 300, usedFraction: 0.2, resetsAt: nil)],
        connectionState: .fresh
    )
}

func aProviderSwitchedOffIsNotRestoredFromTheArchive() throws {
    let restored = UnreadCapacity.snapshots(
        restoring: [read(.codex), read(.claudeCode)],
        switchedOff: [.codex],
        capturedAt: now
    )
    let codex = restored.first { $0.provider == .codex }
    let claude = restored.first { $0.provider == .claudeCode }

    try expect(codex?.isSwitchedOff == true, "Codex was switched off, so its last reading does not come back")
    try expect(codex?.windows.isEmpty == true, "and it shows no numbers, got \(codex?.windows.count ?? -1)")
    try expect(claude?.windows.count == 1 && claude?.isSwitchedOff == false, "Claude Code, still on, keeps its reading")
}

func onlyTheProvidersSwitchedOnHaveCards() throws {
    let codexOff = UnreadCapacity.snapshot(for: .codex, capturedAt: now)
    let shown = SurfaceCards.shown([codexOff, read(.claudeCode)])
    try expect(
        shown.map(\.provider) == [.claudeCode],
        "With Codex switched off, Claude Code's card has the width to itself, got \(shown.map(\.provider))"
    )

    let allOff = UnreadCapacity.snapshots(capturedAt: now)
    try expect(
        SurfaceCards.shown(allOff).isEmpty,
        "With nothing switched on, no Provider has a card of its own, got \(SurfaceCards.shown(allOff).map(\.provider))"
    )

    let failing = CapacitySnapshot.disconnected(provider: .codex, capturedAt: now, reason: .providerNotInstalled)
    try expect(
        SurfaceCards.shown([failing, read(.claudeCode)]).count == 2,
        "A Provider that is on but failing keeps its card, to say why"
    )
}

func nothingConnectedOffersEveryProvidersMarkInOrder() throws {
    let allOff = UnreadCapacity.snapshots(capturedAt: now)
    try expect(
        SurfaceCards.offered(allOff) == [.codex, .claudeCode, .openCode],
        "Nothing on: the marks of Codex, Claude Code and OpenCode, in that order, got \(SurfaceCards.offered(allOff))"
    )
    try expect(
        SurfaceCards.offered(allOff.reversed()) == [.codex, .claudeCode, .openCode],
        "in that order whatever order the snapshots come in"
    )

    let oneOn = allOff.map { $0.provider == .openCode ? read(.openCode) : $0 }
    try expect(SurfaceCards.offered(oneOn).isEmpty, "One on: no marks, got \(SurfaceCards.offered(oneOn))")
    try expect(
        SurfaceCards.shown(oneOn).map(\.provider) == [.openCode],
        "and its card alone, across the width, got \(SurfaceCards.shown(oneOn).map(\.provider))"
    )
    try expect(SurfaceCards.offered([]).isEmpty, "Nothing known yet is not nothing connected")
}
