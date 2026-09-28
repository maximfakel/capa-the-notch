import Foundation

public enum Provider: String, Equatable, Sendable, CaseIterable {
    case codex
    case claudeCode
}

/// Why a Provider has no Capacity to show, together with the one action that
/// would fix it. A disconnected Provider is never drawn as zero Capacity.
public enum CapacityStatusReason: Equatable, Sendable {
    case providerNotInstalled
    case providerIncompatible(detail: String)
    case providerNotAuthenticated
    case providerUnavailable(detail: String)
    case providerAnswerNotUnderstood
    case providerCouldNotRead(detail: String)
    case codexDisconnected
    case claudeDisconnected
    case claudeStatusLineStale
    case claudeStatusLineUnavailable
    case claudeCodeNotInstalled
    case claudeUsageFailed
    case claudeUsageNotUnderstood
    case staleFromArchive

    public var guidance: String {
        switch self {
        case .providerNotInstalled:
            "Install the Codex CLI, then try again."
        case let .providerIncompatible(detail):
            "Update the Codex CLI — \(detail)"
        case .providerNotAuthenticated:
            "Sign in with `codex login`, then try again."
        case let .providerUnavailable(detail):
            "Codex is not answering — \(detail)"
        case .providerAnswerNotUnderstood:
            "Codex answered in a form Capacity Notch cannot read. Update Capacity Notch."
        case let .providerCouldNotRead(detail):
            "Codex could not read its Capacity — \(detail.hasSuffix(".") ? detail : detail + ".") Retrying."
        case .codexDisconnected:
            "Turn on Codex in Settings to read its Capacity."
        case .claudeDisconnected:
            "Turn on Claude Code in Settings to read its Capacity."
        case .claudeStatusLineStale:
            "Run Claude Code in a terminal to update its last published Capacity."
        case .claudeStatusLineUnavailable:
            "Claude Code has not published Capacity yet. Configure the Capacity Notch status-line bridge, then run Claude Code in a terminal."
        case .claudeCodeNotInstalled:
            "Install Claude Code, then try again."
        case .claudeUsageFailed:
            "Claude Code did not answer. Check that it is signed in, then refresh."
        case .claudeUsageNotUnderstood:
            "Claude Code's usage report has changed and Capacity Notch cannot read it. Update Capacity Notch."
        case .staleFromArchive:
            "Last seen before Capacity Notch restarted. Refreshing."
        }
    }

    /// The guidance in the language Settings speak. A Provider's own detail
    /// stays as it came: it is the Provider's words, not ours to translate.
    public var localizedGuidance: String {
        switch self {
        case let .providerIncompatible(detail):
            Localization.format("Update the Codex CLI — %@", detail)
        case let .providerUnavailable(detail):
            Localization.format("Codex is not answering — %@", detail)
        case let .providerCouldNotRead(detail):
            Localization.format("Codex could not read its Capacity — %@ Retrying.", detail.hasSuffix(".") ? detail : detail + ".")
        default:
            Localization.text(guidance)
        }
    }

    /// Whether the card's chip already carries this, so spelling it out in a
    /// sentence underneath would only repeat it.
    public var repeatsTheChip: Bool {
        self == .staleFromArchive
    }

    /// The reason as a word a bug report can carry.
    ///
    /// Deliberately not the guidance sentence and never the detail: a detail
    /// comes from a Provider's own error text, and a Provider's error text is
    /// the one place a token, a path or an address can appear.
    ///
    /// Under 32 characters: `Redaction` treats a longer run of letters and
    /// hyphens as an opaque secret, and would rub the code out of the report.
    public var diagnosticCode: String {
        switch self {
        case .providerNotInstalled: "provider-not-installed"
        case .providerIncompatible: "provider-incompatible"
        case .providerNotAuthenticated: "provider-not-authenticated"
        case .providerUnavailable: "provider-unavailable"
        case .providerAnswerNotUnderstood: "provider-answer-not-understood"
        case .providerCouldNotRead: "provider-could-not-read"
        case .codexDisconnected: "codex-disconnected"
        case .claudeDisconnected: "claude-disconnected"
        case .claudeStatusLineStale: "claude-status-line-stale"
        case .claudeStatusLineUnavailable: "claude-status-line-unavailable"
        case .claudeCodeNotInstalled: "claude-code-not-installed"
        case .claudeUsageFailed: "claude-usage-failed"
        case .claudeUsageNotUnderstood: "claude-usage-not-understood"
        case .staleFromArchive: "stale-from-archive"
        }
    }

    /// Whether a person has to do something before any button here can help:
    /// install a tool, sign in, update one. Connect cannot do those.
    public var needsAPersonFirst: Bool {
        switch self {
        case .providerNotInstalled,
             .providerIncompatible,
             .providerNotAuthenticated,
             .providerAnswerNotUnderstood,
             .claudeStatusLineUnavailable,
             .claudeCodeNotInstalled,
             .claudeUsageNotUnderstood:
            true
        case .providerUnavailable,
             .providerCouldNotRead,
             .codexDisconnected,
             .claudeDisconnected,
             .claudeStatusLineStale,
             .claudeUsageFailed,
             .staleFromArchive:
            false
        }
    }

    /// Whether trying again could clear this on its own.
    ///
    /// A transient failure is worth backing off and retrying: the network, a
    /// Provider that stopped answering, a reading that has simply aged. A
    /// terminal one waits for a person — an install, a sign-in, an update, a
    /// deliberate connect — and retrying it only burns the machine.
    public var isTransient: Bool {
        switch self {
        case .providerUnavailable,
             .providerCouldNotRead,
             .claudeStatusLineStale,
             .claudeUsageFailed,
             .staleFromArchive:
            true
        case .providerNotInstalled,
             .providerIncompatible,
             .providerNotAuthenticated,
             .providerAnswerNotUnderstood,
             .codexDisconnected,
             .claudeDisconnected,
             .claudeStatusLineUnavailable,
             .claudeCodeNotInstalled,
             .claudeUsageNotUnderstood:
            false
        }
    }
}

public enum CapacityConnectionState: Equatable, Sendable {
    case mock
    /// Asked, not yet answered. Distinct from disconnected: nothing is wrong
    /// yet, and distinct from stale: there is nothing to keep showing.
    case connecting
    case fresh
    case stale
    case disconnected(CapacityStatusReason)
}

public struct QuotaWindow: Equatable, Sendable {
    public let id: String
    public let label: String
    public let durationMinutes: Int?
    public let usedFraction: Double
    public let resetsAt: Date?

    public init(
        id: String,
        label: String,
        durationMinutes: Int? = nil,
        usedFraction: Double,
        resetsAt: Date?
    ) {
        self.id = id
        self.label = label
        self.durationMinutes = durationMinutes
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
    }

    public var remainingPercentage: Double {
        ((1 - usedFraction) * 100).rounded()
    }
}

public struct CapacitySnapshot: Equatable, Sendable {
    public let provider: Provider
    public let capturedAt: Date
    public let windows: [QuotaWindow]
    public let connectionState: CapacityConnectionState
    public let statusReason: CapacityStatusReason?

    public init(
        provider: Provider,
        capturedAt: Date,
        windows: [QuotaWindow],
        connectionState: CapacityConnectionState,
        statusReason: CapacityStatusReason? = nil
    ) {
        self.provider = provider
        self.capturedAt = capturedAt
        self.windows = windows
        self.connectionState = connectionState
        self.statusReason = statusReason
    }

    /// A Provider that cannot be read carries no Quota Windows, so no surface
    /// can mistake an unreadable Provider for an exhausted one.
    public static func disconnected(
        provider: Provider,
        capturedAt: Date,
        reason: CapacityStatusReason
    ) -> CapacitySnapshot {
        CapacitySnapshot(
            provider: provider,
            capturedAt: capturedAt,
            windows: [],
            connectionState: .disconnected(reason),
            statusReason: reason
        )
    }
}
