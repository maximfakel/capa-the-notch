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

    let bothOff = UnreadCapacity.snapshots(capturedAt: now)
    try expect(
        SurfaceCards.shown(bothOff).count == 2,
        "With nothing switched on, both cards stay, each offering to connect"
    )

    let failing = CapacitySnapshot.disconnected(provider: .codex, capturedAt: now, reason: .providerNotInstalled)
    try expect(
        SurfaceCards.shown([failing, read(.claudeCode)]).count == 2,
        "A Provider that is on but failing keeps its card, to say why"
    )
}
