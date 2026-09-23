import Foundation

/// One thing worth interrupting someone for.
public struct CapacityAlert: Equatable, Sendable {
    public let provider: Provider
    public let windowID: String
    public let title: String
    public let body: String

    public init(provider: Provider, windowID: String, title: String, body: String) {
        self.provider = provider
        self.windowID = windowID
        self.title = title
        self.body = body
    }
}

/// Decides when a Quota Window is worth interrupting someone for, and — far
/// more of the work — when it is not.
///
/// An alerting surface earns its keep once and loses it on the second
/// duplicate. So: only a Fresh reading speaks, only the moment a window
/// *becomes* critical speaks, and a window that has already spoken stays quiet
/// until it either recovers or turns over.
public struct CapacityAlertDecider: Sendable {
    /// What has already been said about one window.
    private struct Spoken: Equatable {
        var wasCritical: Bool
        var alertedForResetAt: Date?
    }

    /// Which window: a window id is only unique within its Provider.
    private struct WindowKey: Hashable {
        let provider: Provider
        let windowID: String
    }

    private var history: [WindowKey: Spoken] = [:]

    public init() {}

    /// The alerts this reading justifies, which is usually none.
    ///
    /// `isEnabled` is asked per Provider rather than read once, so turning a
    /// Provider off silences it immediately rather than at the next launch.
    public mutating func alerts(
        for snapshot: CapacitySnapshot,
        at now: Date,
        isEnabled: (Provider) -> Bool
    ) -> [CapacityAlert] {
        // Only a Fresh reading may speak. A Stale one is describing the past,
        // a disconnected one knows nothing, and neither is news.
        guard snapshot.connectionState == .fresh else { return [] }

        var raised: [CapacityAlert] = []

        for window in snapshot.windows {
            let key = WindowKey(provider: snapshot.provider, windowID: window.id)
            let isCritical = window.pace == .unsustainable
            var spoken = history[key] ?? Spoken(wasCritical: false, alertedForResetAt: nil)

            defer { history[key] = spoken }

            guard isCritical else {
                // Recovered. The next fall is news again.
                spoken.wasCritical = false
                spoken.alertedForResetAt = nil
                continue
            }

            // A window that has turned over since it last spoke is a new
            // window, whatever its id says.
            let turnedOver = spoken.alertedForResetAt.map { previous in
                window.resetsAt.map { $0 > previous } ?? false
            } ?? false

            guard !spoken.wasCritical || turnedOver else { continue }

            spoken.wasCritical = true
            spoken.alertedForResetAt = window.resetsAt

            // Asked last, so that a silenced Provider still has its history
            // kept: switching alerts back on should not replay what happened
            // while they were off.
            guard isEnabled(snapshot.provider) else { continue }

            raised.append(
                CapacityAlert(
                    provider: snapshot.provider,
                    windowID: window.id,
                    title: "\(snapshot.provider.spokenName) is running out",
                    body: Self.body(for: window, at: now)
                )
            )
        }

        return raised
    }

    private static func body(for window: QuotaWindow, at now: Date) -> String {
        let left = "\(window.label): \(Int(window.remainingPercentage))% left"
        guard let resetsAt = window.resetsAt else { return left }
        return "\(left), resets in \(ResetCountdown.text(until: resetsAt, at: now))"
    }

    /// Forgets everything said, for a Provider that has been disconnected on
    /// purpose. Reconnecting it later should be able to tell you the news.
    public mutating func forget(_ provider: Provider) {
        history = history.filter { $0.key.provider != provider }
    }
}
