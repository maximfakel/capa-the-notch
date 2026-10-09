import Foundation

/// Reads Claude Capacity through Claude Code itself: what its status line,
/// or CapaTheNotch's mod after a reply, hands the bridge (ADR 0001, amended
/// 2026-10-06 and 2026-10-08). This service has no credential or network
/// boundary, so it cannot pull a reading: a refresh re-reads the file, and
/// says where the next reading comes from when there is nothing newer.
public actor ClaudeCapacityService {
    private let now: @Sendable () -> Date
    private let capacitySource: any ClaudeCapacitySource
    private let staleAfter: TimeInterval
    /// Whether a reply anywhere brings the next reading (the mod is
    /// installed), or only one in a terminal (the status line alone).
    private let nextReadingFromAnyReply: @Sendable () -> Bool
    private var isConnected = false
    private var lastSuccessfulSnapshot: CapacitySnapshot?

    public nonisolated let snapshots: AsyncStream<CapacitySnapshot>
    private nonisolated let snapshotContinuation: AsyncStream<CapacitySnapshot>.Continuation

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        capacitySource: any ClaudeCapacitySource,
        staleAfter: TimeInterval = ClaudeCapacityReading.freshFor,
        nextReadingFromAnyReply: @escaping @Sendable () -> Bool = { false }
    ) {
        self.now = now
        self.nextReadingFromAnyReply = nextReadingFromAnyReply
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

    /// Reads the bridge's file again. `asked` when a person pressed Refresh:
    /// a reading no newer than the one shown then says it waits for Claude's
    /// next reply, and how old it is.
    public func refresh(asked: Bool = false) async {
        guard isConnected else { return }

        do {
            let reading = try capacitySource.read()
            let isStale = now().timeIntervalSince(reading.capturedAt) > staleAfter
            let nothingNewer = asked && lastSuccessfulSnapshot.map { reading.capturedAt <= $0.capturedAt } == true
            let anyReply = nextReadingFromAnyReply()
            let reason: CapacityStatusReason? = if nothingNewer {
                .claudeNextReply(lastReadAt: reading.capturedAt, anyReply: anyReply)
            } else if isStale {
                anyReply ? .claudeStaleUntilReply : .claudeStatusLineStale
            } else {
                nil
            }
            let snapshot = CapacitySnapshot(
                provider: .claudeCode,
                capturedAt: reading.capturedAt,
                windows: reading.windows,
                connectionState: isStale ? .stale : .fresh,
                statusReason: reason
            )
            lastSuccessfulSnapshot = snapshot
            snapshotContinuation.yield(snapshot)
        } catch {
            holdLastCapacityOrDisconnect(reasonForNoReading())
        }
    }

    /// The failure said as the one thing that would fix it: the bridge has
    /// published nothing yet, and a reply will make it.
    private func reasonForNoReading() -> CapacityStatusReason {
        nextReadingFromAnyReply() ? .claudeNextReply(lastReadAt: nil, anyReply: true) : .claudeStatusLineUnavailable
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
