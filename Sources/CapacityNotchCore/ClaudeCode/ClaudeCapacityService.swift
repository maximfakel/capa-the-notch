import Foundation

/// Reads Claude Capacity through Claude Code itself: its own `/usage`, and the
/// status-line bridge where one runs. This service has no credential or
/// network boundary.
public actor ClaudeCapacityService {
    private let now: @Sendable () -> Date
    private let capacitySource: any ClaudeCapacitySource
    private let staleAfter: TimeInterval
    private var isConnected = false
    private var lastSuccessfulSnapshot: CapacitySnapshot?

    public nonisolated let snapshots: AsyncStream<CapacitySnapshot>
    private nonisolated let snapshotContinuation: AsyncStream<CapacitySnapshot>.Continuation

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        capacitySource: any ClaudeCapacitySource,
        staleAfter: TimeInterval = ClaudeCapacityReading.freshFor
    ) {
        self.now = now
        self.capacitySource = capacitySource
        self.staleAfter = staleAfter

        var capturedContinuation: AsyncStream<CapacitySnapshot>.Continuation!
        snapshots = AsyncStream { capturedContinuation = $0 }
        snapshotContinuation = capturedContinuation
    }

    public func connect() async {
        guard !isConnected else { return }
        isConnected = true
        await refresh()
    }

    public func refresh() async {
        guard isConnected else { return }

        do {
            let reading = try capacitySource.read()
            let isStale = now().timeIntervalSince(reading.capturedAt) > staleAfter
            let snapshot = CapacitySnapshot(
                provider: .claudeCode,
                capturedAt: reading.capturedAt,
                windows: reading.windows,
                connectionState: isStale ? .stale : .fresh,
                statusReason: isStale ? .claudeStatusLineStale : nil
            )
            lastSuccessfulSnapshot = snapshot
            snapshotContinuation.yield(snapshot)
        } catch {
            holdLastCapacityOrDisconnect(Self.reason(for: error))
        }
    }

    /// The failure said as the one thing that would fix it. `/usage` fails in
    /// three different ways and each wants a different hand; anything else
    /// came from the status-line bridge.
    private static func reason(for error: Error) -> CapacityStatusReason {
        switch error as? ClaudeUsageCommandError {
        case .claudeCodeNotInstalled: .claudeCodeNotInstalled
        case .commandFailed: .claudeUsageFailed
        case .outputNotUnderstood: .claudeUsageNotUnderstood
        case nil: .claudeStatusLineUnavailable
        }
    }

    public func disconnect() {
        isConnected = false
        lastSuccessfulSnapshot = nil
        emitDisconnected(.claudeDisconnected)
    }

    private func emitDisconnected(_ reason: CapacityStatusReason) {
        snapshotContinuation.yield(
            CapacitySnapshot.disconnected(
                provider: .claudeCode,
                capturedAt: now(),
                reason: reason
            )
        )
    }

    private func holdLastCapacityOrDisconnect(_ reason: CapacityStatusReason) {
        guard let lastSuccessfulSnapshot else {
            emitDisconnected(reason)
            return
        }

        snapshotContinuation.yield(
            CapacitySnapshot(
                provider: .claudeCode,
                capturedAt: lastSuccessfulSnapshot.capturedAt,
                windows: lastSuccessfulSnapshot.windows,
                connectionState: .stale,
                statusReason: reason
            )
        )
    }
}
