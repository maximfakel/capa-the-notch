import Foundation

/// What the surface shows before a Provider has been read.
///
/// Each Provider states that it has nothing yet and how to change that. There
/// are no invented numbers: a surface that shows a figure is showing a figure
/// that came from a Provider.
public enum UnreadCapacity {
    public static func snapshots(capturedAt: Date = .now) -> [CapacitySnapshot] {
        Provider.allCases.map { snapshot(for: $0, capturedAt: capturedAt) }
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
            reason: provider.switchedOffReason
        )
    }
}

public extension CapacitySnapshot {
    /// Not being read because the person has it switched off, as opposed to
    /// switched on and failing.
    var isSwitchedOff: Bool {
        statusReason == provider.switchedOffReason
    }
}

public extension Provider {
    /// What a Provider says while the person has it switched off.
    var switchedOffReason: CapacityStatusReason {
        switch self {
        case .codex: .codexDisconnected
        case .claudeCode: .claudeDisconnected
        case .openCode: .openCodeDisconnected
        }
    }
}

/// Which Providers have a card on the open surface.
///
/// A Provider switched off has none, and the other takes the width
/// ("Notch — Expanded — One provider"). With every Provider off, none has a
/// card: the surface offers them all at once instead ("Notch — Disconnected
/// · Three Providers").
public enum SurfaceCards {
    public static func shown(_ snapshots: [CapacitySnapshot]) -> [CapacitySnapshot] {
        ProviderSelection.ordered(snapshots.filter { !$0.isSwitchedOff })
    }

    /// The Providers whose marks stand over the one button to Settings ▸
    /// Providers: every one, in order, while nothing is connected, and none
    /// otherwise. Connecting, and its consent, happens in Settings.
    public static func offered(_ snapshots: [CapacitySnapshot]) -> [Provider] {
        nothingConnected(snapshots) ? ProviderSelection.ordered(Provider.allCases) : []
    }
}

/// Which Providers the surface shows, and in what order.
///
/// One order everywhere — the order Providers are listed in: Codex, Claude
/// Code, then any later one — so a Provider keeps its side of the strip and
/// its place among the cards whatever order it was turned on in. At most two
/// are on at once: the strip has two sides and the open surface room for two
/// cards.
public enum ProviderSelection {
    public static let visibleLimit = 2
    // `limit` below is never passed in production: it lets the tests see a
    // refusal while only two Providers exist.

    public static func ordered(_ providers: some Sequence<Provider>) -> [Provider] {
        let chosen = Set(providers)
        return Provider.allCases.filter(chosen.contains)
    }

    static func ordered(_ snapshots: [CapacitySnapshot]) -> [CapacitySnapshot] {
        snapshots.sorted { position($0.provider) < position($1.provider) }
    }

    /// Whether this Provider may be on alongside those already on. One
    /// already on may always stay on.
    public static func canTurnOn(_ provider: Provider, alreadyOn: Set<Provider>, limit: Int = visibleLimit) -> Bool {
        alreadyOn.contains(provider) || alreadyOn.count < limit
    }

    /// The Providers to connect from those chosen: the first in order, up to
    /// the limit, should more have been chosen somewhere this rule was not.
    public static func toConnect(_ chosen: some Sequence<Provider>, limit: Int = visibleLimit) -> [Provider] {
        Array(ordered(chosen).prefix(limit))
    }

    private static func position(_ provider: Provider) -> Int {
        Provider.allCases.firstIndex(of: provider) ?? Provider.allCases.count
    }
}

public extension SurfaceCards {
    /// Every Provider switched off: opened, the surface shows the Providers'
    /// marks ("Notch — Disconnected · Three Providers"); closed, the strip is
    /// empty. It is not held open.
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
/// unless asked otherwise — the first in `ProviderSelection` order left and
/// the second right. One on: that Provider alone, its shortest window left
/// and its longest right — "5 ч" and "Неделя" ("Notch — Compact — One
/// provider"). None on: nothing, as the surface is open anyway.
public enum CompactStrip {
    public enum Side: Equatable, Sendable {
        /// A Provider's Headline Window, or a dash while it has none.
        case provider(CapacitySnapshot)
        /// One window of the only Provider on.
        case window(Provider, QuotaWindow)
    }

    public static func sides(_ snapshots: [CapacitySnapshot], showing choice: CompactWindowChoice = .fiveHour) -> (left: Side?, right: Side?) {
        let on = ProviderSelection.ordered(snapshots.filter { !$0.isSwitchedOff })
        guard on.count == 1, let only = on.first else {
            guard !on.isEmpty else { return (nil, nil) }
            func chosen(_ snapshot: CapacitySnapshot?) -> Side? {
                guard let snapshot else { return nil }
                let provider = snapshot.provider
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
            return (chosen(on.first), chosen(on.dropFirst().first))
        }
        let windows = byDuration(only.windows)
        guard let shortest = windows.first else {
            // Nothing read yet: a dash on the left, where its five hours
            // will stand once read.
            return (.provider(only), nil)
        }
        guard windows.count > 1, let longest = windows.last else { return (.window(only.provider, shortest), nil) }
        return (.window(only.provider, shortest), .window(only.provider, longest))
    }

    private static func byDuration(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        windows.sorted { ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max) }
    }
}
