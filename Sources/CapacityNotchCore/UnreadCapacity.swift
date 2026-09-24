import Foundation

/// What the surface shows before a Provider has been read.
///
/// Each Provider states that it has nothing yet and how to change that. There
/// are no invented numbers: a surface that shows a figure is showing a figure
/// that came from a Provider.
public enum UnreadCapacity {
    public static func snapshots(capturedAt: Date = .now) -> [CapacitySnapshot] {
        [
            snapshot(for: .codex, capturedAt: capturedAt),
            snapshot(for: .claudeCode, capturedAt: capturedAt),
        ]
    }

    /// The same, with anything remembered from a previous run put back in
    /// place. A Provider with nothing archived still says it has not been
    /// read; one with a reading shows it, marked Stale.
    ///
    /// A Provider the person switched off is not put back: its last reading
    /// would sit on the surface, never to be refreshed.
    public static func snapshots(
        restoring archived: [CapacitySnapshot],
        switchedOff: Set<Provider> = [],
        capturedAt: Date = .now
    ) -> [CapacitySnapshot] {
        snapshots(capturedAt: capturedAt).map { unread in
            guard !switchedOff.contains(unread.provider) else { return unread }
            return archived.first { $0.provider == unread.provider } ?? unread
        }
    }

    /// One Provider, unread: what it shows once switched off.
    public static func snapshot(for provider: Provider, capturedAt: Date = .now) -> CapacitySnapshot {
        CapacitySnapshot.disconnected(
            provider: provider,
            capturedAt: capturedAt,
            reason: provider == .codex ? .codexDisconnected : .claudeDisconnected
        )
    }
}

public extension CapacitySnapshot {
    /// Not being read because the person has it switched off, as opposed to
    /// switched on and failing.
    var isSwitchedOff: Bool {
        statusReason == .codexDisconnected || statusReason == .claudeDisconnected
    }
}

/// Which Providers have a card on the open surface.
///
/// A Provider switched off has none, and the other takes the width
/// ("Notch — Expanded — One provider"). With every Provider off, both cards
/// stay, each offering to connect ("Notch — Disconnected").
public enum SurfaceCards {
    public static func shown(_ snapshots: [CapacitySnapshot]) -> [CapacitySnapshot] {
        let on = snapshots.filter { !$0.isSwitchedOff }
        return on.isEmpty ? snapshots : on
    }
}
