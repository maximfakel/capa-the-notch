import Foundation

/// Turns a Codex rate-limit payload into a Capacity Snapshot.
public enum CodexCapacityMapper {
    public static func snapshot(
        from payload: CodexRateLimitSnapshot,
        capturedAt: Date,
        connectionState: CapacityConnectionState = .fresh,
        statusReason: CapacityStatusReason? = nil
    ) -> CapacitySnapshot {
        let windows = [
            payload.primary.map { window(from: $0, id: "codex-primary") },
            payload.secondary.map { window(from: $0, id: "codex-secondary") },
        ].compactMap(\.self)

        return CapacitySnapshot(
            provider: .codex,
            capturedAt: capturedAt,
            windows: windows,
            connectionState: connectionState,
            statusReason: statusReason
        )
    }

    /// A rolling update is sparse: a window it omits keeps its last value
    /// rather than dropping out of the surface.
    public static func merge(
        _ update: CodexRateLimitSnapshot,
        into previous: CodexRateLimitSnapshot
    ) -> CodexRateLimitSnapshot {
        CodexRateLimitSnapshot(
            primary: update.primary ?? previous.primary,
            secondary: update.secondary ?? previous.secondary
        )
    }

    private static func window(from payload: CodexRateLimitWindow, id: String) -> QuotaWindow {
        QuotaWindow(
            id: id,
            label: label(forWindowDurationMins: payload.windowDurationMins),
            durationMinutes: payload.windowDurationMins,
            usedFraction: min(max(Double(payload.usedPercent) / 100, 0), 1),
            resetsAt: payload.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    public static func label(forWindowDurationMins minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Quota" }

        switch minutes {
        case 10080:
            return "Weekly"
        case ..<60:
            return "\(minutes) minute"
        default:
            break
        }

        if minutes % 1440 == 0 {
            let days = minutes / 1440
            return days == 1 ? "Daily" : "\(days) day"
        }

        if minutes % 60 == 0 {
            return "\(minutes / 60) hour"
        }

        return "\(minutes) minute"
    }
}
