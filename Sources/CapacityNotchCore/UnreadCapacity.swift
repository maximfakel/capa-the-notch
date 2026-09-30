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

public extension SurfaceCards {
    /// Every Provider switched off: the surface stays open on its two
    /// Connect cards, since a closed strip would have nothing to show
    /// ("Notch — Disconnected").
    static func nothingConnected(_ snapshots: [CapacitySnapshot]) -> Bool {
        !snapshots.isEmpty && snapshots.allSatisfy(\.isSwitchedOff)
    }
}

/// Which window each Provider shows in the closed strip while both are on.
public enum CompactWindowChoice: String, CaseIterable, Sendable {
    case fiveHour
    case weekly
    case leastLeft

    /// The words in Settings, as drawn.
    public var title: String {
        switch self {
        case .fiveHour: Localization.text("Five-hour")
        case .weekly: Localization.text("Weekly")
        case .leastLeft: Localization.text("Least left")
        }
    }
}

/// What the closed strip shows either side of the notch.
///
/// Two Providers on: each the window chosen in Settings — its five hours
/// unless asked otherwise — Codex left and Claude Code right. One on: that Provider alone, its shortest window left and its
/// longest right — "5 ч" and "Неделя" ("Notch — Compact — One provider").
/// None on: nothing, as the surface is open anyway.
public enum CompactStrip {
    public enum Side: Equatable, Sendable {
        /// A Provider's Headline Window, or a dash while it has none.
        case provider(CapacitySnapshot)
        /// One window of the only Provider on.
        case window(Provider, QuotaWindow)
    }

    public static func sides(_ snapshots: [CapacitySnapshot], showing choice: CompactWindowChoice = .fiveHour) -> (left: Side?, right: Side?) {
        let on = snapshots.filter { !$0.isSwitchedOff }
        guard on.count == 1, let only = on.first else {
            guard !on.isEmpty else { return (nil, nil) }
            func chosen(_ provider: Provider) -> Side? {
                guard let snapshot = on.first(where: { $0.provider == provider }) else { return nil }
                let windows = byDuration(snapshot.windows)
                // The window of that length, and only without one the
                // nearest end: a Provider's shortest is not always five hours.
                let window = switch choice {
                case .fiveHour: windows.first { $0.durationMinutes == 5 * 60 } ?? windows.first
                case .weekly: windows.first { $0.durationMinutes == 7 * 24 * 60 } ?? windows.last
                case .leastLeft: snapshot.headlineWindow
                }
                return window.map { .window(provider, $0) } ?? .provider(snapshot)
            }
            return (chosen(.codex), chosen(.claudeCode))
        }
        let windows = byDuration(only.windows)
        guard let shortest = windows.first else {
            // Nothing read yet: the Provider keeps its own side, with a dash.
            return only.provider == .codex ? (.provider(only), nil) : (nil, .provider(only))
        }
        guard windows.count > 1, let longest = windows.last else { return (.window(only.provider, shortest), nil) }
        return (.window(only.provider, shortest), .window(only.provider, longest))
    }

    private static func byDuration(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        windows.sorted { ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max) }
    }
}
