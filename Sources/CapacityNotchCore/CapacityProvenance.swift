import Foundation

/// What the surface as a whole is currently showing, so its header can say so
/// instead of claiming mock Capacity over live readings.
public enum CapacityProvenance: Equatable, Sendable {
    /// Nothing has been read from a Provider yet.
    case mock
    /// At least one Provider was read, and the newest reading is current.
    case fresh(Date)
    /// A Provider is showing Capacity whose refresh has since failed.
    case stale(Date)
    /// Every Provider that is not mock is unreadable.
    case disconnected

    public static func of(_ snapshots: [CapacitySnapshot]) -> CapacityProvenance {
        let observed = snapshots.filter { $0.connectionState != .mock }
        guard !observed.isEmpty else { return .mock }

        let stale = observed.filter { $0.connectionState == .stale }
        if let newest = stale.map(\.capturedAt).max() {
            return .stale(newest)
        }

        let fresh = observed.filter { $0.connectionState == .fresh }
        if let newest = fresh.map(\.capturedAt).max() {
            return .fresh(newest)
        }

        return .disconnected
    }
}
