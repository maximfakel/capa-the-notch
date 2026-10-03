import Foundation

/// How comfortable a window's remaining Capacity is, read off what is left.
///
/// Three bands, with the boundaries in `CapacityPaceRule`. The time still to
/// run does not enter into it; the reset is on the card for anyone who wants
/// to weigh it.
public enum CapacityPace: Equatable, Sendable, Comparable {
    /// Plenty left.
    case sustainable
    /// Enough left to notice.
    case tightening
    /// Nearly gone, or gone.
    case unsustainable

    /// Worst first, so a sort puts the window that needs attention on top.
    public static func < (lhs: CapacityPace, rhs: CapacityPace) -> Bool {
        lhs.severity < rhs.severity
    }

    private var severity: Int {
        switch self {
        case .unsustainable: 0
        case .tightening: 1
        case .sustainable: 2
        }
    }
}

/// The boundaries, in one place, so they can be quoted rather than guessed at.
///
/// They are read off what is left, and nothing else. An earlier rule weighed
/// the remainder against the time still to run, which is defensible and was
/// wrong for this surface: it painted eleven percent green because the window
/// happened to reset in two hours, and a person glancing at the strip reads
/// eleven percent as nearly gone whatever the clock says. The surface now
/// says what it shows.
public enum CapacityPaceRule {
    public static let sustainablePercentage = 60.0
    public static let tighteningPercentage = 10.0

    /// A boundary belongs to the better state, and binary fractions do not
    /// land on it exactly: 90% used leaves 0.09999999999999998. The slack is
    /// far below anything a rounded percentage can express.
    public static let tolerance = 1e-9
}

public extension QuotaWindow {
    /// Share of the allowance still unspent, from 0 to 1.
    var remainingFraction: Double {
        min(max(1 - usedFraction, 0), 1)
    }

    var pace: CapacityPace {
        // Nothing left is nothing left.
        guard remainingFraction > 0 else { return .unsustainable }

        let remaining = remainingPercentage
        if remaining >= CapacityPaceRule.sustainablePercentage - CapacityPaceRule.tolerance {
            return .sustainable
        }
        if remaining >= CapacityPaceRule.tighteningPercentage - CapacityPaceRule.tolerance {
            return .tightening
        }
        return .unsustainable
    }
}

public extension CapacitySnapshot {
    /// The Quota Window that represents this Provider in the compact strip:
    /// the one with the least left. An earlier reset breaks a tie, so the
    /// choice is the same every time it is made.
    var headlineWindow: QuotaWindow? {
        windows.min { left, right in
            if left.remainingPercentage != right.remainingPercentage {
                return left.remainingPercentage < right.remainingPercentage
            }
            return (left.resetsAt ?? .distantFuture) < (right.resetsAt ?? .distantFuture)
        }
    }
}

/// How long until a window turns over, in the fewest words that stay honest.
public enum ResetCountdown {
    public static func text(until resetsAt: Date, at now: Date) -> String {
        let remaining = Int(resetsAt.timeIntervalSince(now).rounded())
        guard remaining > 0 else { return Localization.text("moments") }

        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60

        if hours >= 24 {
            let days = hours / 24
            let spareHours = hours % 24
            return spareHours > 0 ? Localization.format("%dd %dh", days, spareHours) : Localization.format("%dd", days)
        }
        if hours > 0 {
            return minutes > 0 ? Localization.format("%dh %dm", hours, minutes) : Localization.format("%dh", hours)
        }
        return remaining >= 60 ? Localization.format("%dm", minutes) : Localization.text("under a minute")
    }
}

/// What a gauge writes in its gap: the time of day the window comes back
/// while that is within a day, how long until it once it is further off, and nothing
/// known when the Provider did not say.
public enum GaugeReset: Equatable, Sendable {
    case at(Date)
    case `in`(String)
    case unknown

    public init(resetsAt: Date?, at now: Date) {
        guard let resetsAt else { self = .unknown; return }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining > 0, remaining < 24 * 3600 {
            self = .at(resetsAt)
        } else {
            self = .in(ResetCountdown.text(until: resetsAt, at: now))
        }
    }
}
