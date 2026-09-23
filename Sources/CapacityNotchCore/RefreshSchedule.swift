import Foundation

/// How long to wait before reading a Provider again.
///
/// Two things set the pace. An open surface is being watched, so it is read
/// often; a closed one is glanced at, so it is read rarely. And a Provider
/// that has just failed is given room: each consecutive failure doubles the
/// wait, up to a ceiling, so a Provider that is down is not hammered and one
/// that recovers is picked up within a few minutes either way.
public struct RefreshSchedule: Equatable, Sendable {
    public let whileExpanded: TimeInterval
    public let whileCompact: TimeInterval
    public let failureCeiling: TimeInterval

    public static let standard = RefreshSchedule(
        whileExpanded: 60,
        whileCompact: 300,
        failureCeiling: 900
    )

    public init(
        whileExpanded: TimeInterval,
        whileCompact: TimeInterval,
        failureCeiling: TimeInterval
    ) {
        self.whileExpanded = whileExpanded
        self.whileCompact = whileCompact
        self.failureCeiling = failureCeiling
    }

    /// The wait before the next read.
    ///
    /// `consecutiveFailures` counts only failures worth retrying. A Provider
    /// waiting on a person is not backed off, because nothing about waiting
    /// longer helps; it is simply read at the surface's own pace.
    public func delay(expanded: Bool, consecutiveFailures: Int) -> TimeInterval {
        let base = expanded ? whileExpanded : whileCompact
        guard consecutiveFailures > 0 else { return base }

        // Doubling, but bounded before it is computed: a large count must not
        // overflow its way to a small number.
        let doublings = min(consecutiveFailures, 16)
        let backed = base * pow(2, Double(doublings))
        return min(backed, failureCeiling)
    }
}
