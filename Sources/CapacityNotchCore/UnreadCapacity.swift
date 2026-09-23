import Foundation

/// What the surface shows before a Provider has been read.
///
/// Each Provider states that it has nothing yet and how to change that. There
/// are no invented numbers: a surface that shows a figure is showing a figure
/// that came from a Provider.
public enum UnreadCapacity {
    public static func snapshots(capturedAt: Date = .now) -> [CapacitySnapshot] {
        [
            CapacitySnapshot.disconnected(
                provider: .codex,
                capturedAt: capturedAt,
                reason: .codexDisconnected
            ),
            CapacitySnapshot.disconnected(
                provider: .claudeCode,
                capturedAt: capturedAt,
                reason: .claudeDisconnected
            ),
        ]
    }

    /// The same, with anything remembered from a previous run put back in
    /// place. A Provider with nothing archived still says it has not been
    /// read; one with a reading shows it, marked Stale.
    public static func snapshots(
        restoring archived: [CapacitySnapshot],
        capturedAt: Date = .now
    ) -> [CapacitySnapshot] {
        snapshots(capturedAt: capturedAt).map { unread in
            archived.first { $0.provider == unread.provider } ?? unread
        }
    }
}
