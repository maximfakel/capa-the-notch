import CapacityNotchCore
import Foundation

private let alertAt = Date(timeIntervalSince1970: 1_700_000_000)
private let always: @Sendable (Provider) -> Bool = { _ in true }

private func snapshot(
    used: Double,
    state: CapacityConnectionState = .fresh,
    resetsIn: TimeInterval = 3600,
    id: String = "five-hour",
    provider: Provider = .codex
) -> CapacitySnapshot {
    CapacitySnapshot(
        provider: provider,
        capturedAt: alertAt,
        windows: [
            QuotaWindow(
                id: id,
                label: "5 hour",
                durationMinutes: 300,
                usedFraction: used,
                resetsAt: alertAt.addingTimeInterval(resetsIn)
            ),
        ],
        connectionState: state
    )
}

func aWindowFallingBelowTenPercentIsWorthSaying() throws {
    var decider = CapacityAlertDecider()

    try expect(
        decider.alerts(for: snapshot(used: 0.85), at: alertAt, isEnabled: always).isEmpty,
        "Fifteen percent left is not news"
    )

    let raised = decider.alerts(for: snapshot(used: 0.96), at: alertAt, isEnabled: always)
    try expect(raised.count == 1, "Four percent left is, got \(raised.count)")
    try expect(raised[0].title.contains("Codex"), "It names the Provider")
    try expect(raised[0].body.contains("4% left"), "And what is left, got \(raised[0].body)")
    try expect(raised[0].body.contains("resets in"), "And how long it has")
}

func aWindowSaysItOnceAndThenKeepsQuiet() throws {
    var decider = CapacityAlertDecider()

    _ = decider.alerts(for: snapshot(used: 0.96), at: alertAt, isEnabled: always)

    for reading in [0.96, 0.97, 0.99, 1.0] {
        try expect(
            decider.alerts(for: snapshot(used: reading), at: alertAt, isEnabled: always).isEmpty,
            "Still running out is not news again, at \(reading)"
        )
    }
}

func aWindowThatRecoversIsNewsWhenItFallsAgain() throws {
    var decider = CapacityAlertDecider()

    _ = decider.alerts(for: snapshot(used: 0.96), at: alertAt, isEnabled: always)
    _ = decider.alerts(for: snapshot(used: 0.40), at: alertAt, isEnabled: always)

    try expect(
        decider.alerts(for: snapshot(used: 0.98), at: alertAt, isEnabled: always).count == 1,
        "Having recovered, falling again is worth saying"
    )
}

func aWindowThatTurnsOverIsANewWindow() throws {
    var decider = CapacityAlertDecider()

    _ = decider.alerts(for: snapshot(used: 0.96, resetsIn: 600), at: alertAt, isEnabled: always)

    try expect(
        decider.alerts(for: snapshot(used: 0.96, resetsIn: 600), at: alertAt, isEnabled: always).isEmpty,
        "The same window is still the same window"
    )
    try expect(
        decider.alerts(for: snapshot(used: 0.96, resetsIn: 18_600), at: alertAt, isEnabled: always).count == 1,
        "A window whose reset has moved on is a new one, whatever its id says"
    )
}

func onlyAFreshReadingSpeaks() throws {
    for state: CapacityConnectionState in [.stale, .connecting, .mock, .disconnected(.providerNotInstalled)] {
        var decider = CapacityAlertDecider()
        try expect(
            decider.alerts(for: snapshot(used: 0.99, state: state), at: alertAt, isEnabled: always).isEmpty,
            "A \(state) reading is not news"
        )
    }
}

func aSilencedProviderIsSilentAndStaysCaughtUp() throws {
    var decider = CapacityAlertDecider()
    let never: @Sendable (Provider) -> Bool = { _ in false }

    try expect(
        decider.alerts(for: snapshot(used: 0.96), at: alertAt, isEnabled: never).isEmpty,
        "A Provider whose alerts are off says nothing"
    )
    try expect(
        decider.alerts(for: snapshot(used: 0.97), at: alertAt, isEnabled: always).isEmpty,
        "And switching them on does not replay what happened while they were off"
    )
    try expect(
        decider.alerts(for: snapshot(used: 0.40), at: alertAt, isEnabled: always).isEmpty,
        "Recovering is never news"
    )
    try expect(
        decider.alerts(for: snapshot(used: 0.96), at: alertAt, isEnabled: always).count == 1,
        "The next fall is"
    )
}

func disconnectingAProviderForgetsWhatWasSaid() throws {
    var decider = CapacityAlertDecider()

    _ = decider.alerts(for: snapshot(used: 0.96), at: alertAt, isEnabled: always)
    decider.forget(.codex)

    try expect(
        decider.alerts(for: snapshot(used: 0.96), at: alertAt, isEnabled: always).count == 1,
        "A Provider reconnected after being switched off can tell you the news"
    )

    // The same window id under the other Provider: forgetting one must not
    // make the other repeat itself.
    _ = decider.alerts(for: snapshot(used: 0.96, provider: .claudeCode), at: alertAt, isEnabled: always)
    decider.forget(.codex)
    try expect(
        decider.alerts(for: snapshot(used: 0.96, provider: .claudeCode), at: alertAt, isEnabled: always).isEmpty,
        "Forgetting Codex keeps what Claude Code has already said"
    )
}
