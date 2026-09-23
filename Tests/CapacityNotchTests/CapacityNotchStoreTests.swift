import Foundation
import CapacityNotchCore

func storeMovesBetweenCompactAndExpandedPresentation() throws {
    let snapshots = MockCapacityCatalog.snapshots(
        capturedAt: Date(timeIntervalSince1970: 20_000)
    )
    let store = CapacityNotchStore(snapshots: snapshots)

    try expect(store.snapshots == snapshots, "Store should expose its Capacity Snapshots")
    try expect(store.presentation == .compact, "Store should begin compact")

    store.expand()
    try expect(store.presentation == .expanded, "Expand should reveal Provider details")

    store.collapse()
    try expect(store.presentation == .compact, "Collapse should return to compact Capacity")
}
