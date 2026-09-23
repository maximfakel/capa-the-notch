import Foundation
import CapacityNotchCore

func mockCatalogProvidesBothInitialProviders() throws {
    let captured = Date(timeIntervalSince1970: 10_000)

    let snapshots = MockCapacityCatalog.snapshots(capturedAt: captured)

    try expect(
        snapshots.map(\.provider) == [.codex, .claudeCode],
        "Mock catalog should provide Codex and Claude Code in display order"
    )
    try expect(
        snapshots.allSatisfy { !$0.windows.isEmpty },
        "Every mock Provider should include at least one Quota Window"
    )
    try expect(
        snapshots.allSatisfy { $0.capturedAt == captured },
        "Every mock snapshot should use the requested capture time"
    )
}

func mockCatalogMarksCapacityAsMock() throws {
    let snapshots = MockCapacityCatalog.snapshots(
        capturedAt: Date(timeIntervalSince1970: 10_000)
    )

    try expect(
        snapshots.allSatisfy { $0.connectionState == .mock },
        "Every mock Capacity Snapshot should explicitly identify mock provenance"
    )
}
