import Foundation
import CapacityNotchCore

func quotaWindowReportsThirtyPercentLeftAfterSeventyPercentIsUsed() throws {
    let reset = Date(timeIntervalSince1970: 1_800)
    let captured = Date(timeIntervalSince1970: 900)
    let window = QuotaWindow(
        id: "five-hour",
        label: "5 hour",
        usedFraction: 0.70,
        resetsAt: reset
    )

    let snapshot = CapacitySnapshot(
        provider: .codex,
        capturedAt: captured,
        windows: [window],
        connectionState: .fresh
    )

    try expect(snapshot.provider == .codex, "Snapshot should belong to Codex")
    try expect(snapshot.capturedAt == captured, "Snapshot should retain its capture time")
    try expect(
        snapshot.windows.first?.remainingPercentage == 30,
        "A window with 70% used should report 30% left"
    )
}
