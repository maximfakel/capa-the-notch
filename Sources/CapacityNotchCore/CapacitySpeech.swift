import Foundation

public extension CapacityPace {
    /// The state said in words, for a screen reader and for anyone who cannot
    /// tell the three colours apart.
    var spoken: String {
        switch self {
        case .sustainable: "on pace"
        case .tightening: "tightening"
        case .unsustainable: "running out"
        }
    }

    // The surface writes no word for the state, and needs none. Capacity Pace
    // is read off the remainder and nothing else, so the colour restates the
    // figure that is already on the row — and a word would restate it a third
    // time. What carries the meaning without colour is the figure itself.
}

/// What a screen reader says about the surface.
///
/// Kept out of the views so the wording can be read, argued with, and tested
/// without rendering anything.
public enum CapacitySpeech {
    /// One Quota Window: which window, what is left, how it is going, how much
    /// has gone, and when it turns over.
    public static func window(
        _ window: QuotaWindow,
        at now: Date,
        formatter: DateFormatter = CapacitySpeech.clock
    ) -> String {
        var parts = [
            "\(window.label) window",
            "\(Int(window.remainingPercentage)) percent left",
            window.pace.spoken,
            "\(Int((window.usedFraction * 100).rounded())) percent used",
        ]

        if let resetsAt = window.resetsAt {
            parts.append(
                "resets in \(ResetCountdown.text(until: resetsAt, at: now)), at \(formatter.string(from: resetsAt))"
            )
        } else {
            parts.append("reset time not reported")
        }

        return parts.joined(separator: ", ")
    }

    /// One Provider: who it is, how its reading stands, and either its windows
    /// or the one thing that would fix it.
    public static func provider(_ snapshot: CapacitySnapshot, at now: Date) -> String {
        var parts = [snapshot.provider.spokenName, snapshot.connectionState.spoken]

        if let reason = snapshot.statusReason, snapshot.connectionState != .fresh {
            parts.append(reason.guidance)
        }

        parts.append(contentsOf: snapshot.windows.map { window($0, at: now) })
        return parts.joined(separator: ". ")
    }

    /// The closed strip's figure for one Provider.
    public static func compact(_ snapshot: CapacitySnapshot, at now: Date) -> String {
        guard let headline = snapshot.headlineWindow else {
            let reason = snapshot.statusReason?.guidance ?? "no Capacity read"
            return "\(snapshot.provider.spokenName), \(reason)"
        }

        return [
            snapshot.provider.spokenName,
            "\(headline.label) window",
            "\(Int(headline.remainingPercentage)) percent left",
            headline.pace.spoken,
        ].joined(separator: ", ")
    }

    public static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

public extension Provider {
    var spokenName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }
}

public extension CapacityConnectionState {
    var spoken: String {
        switch self {
        case .mock: "mock Capacity"
        case .connecting: "connecting"
        case .fresh: "Fresh Capacity"
        case .stale: "Stale Capacity"
        case .disconnected: "disconnected"
        }
    }
}
