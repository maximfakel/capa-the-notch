import Foundation

public enum Provider: String, Equatable, Sendable, CaseIterable {
    case codex
    case claudeCode
    /// OpenCode's Go plan, read with its own key (ADR 0001, amended).
    case openCode
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
    /// Claude Code's Capacity cannot be pulled: it arrives when Claude
    /// answers. Said when a refresh found nothing newer, with how old the
    /// last reading is; `anyReply` when CapaTheNotch's mod is installed, so a
    /// reply anywhere — the desktop app, VS Code, a terminal — brings it.
    case claudeNextReply(lastReadAt: Date?, anyReply: Bool)
    /// An old reading, with the mod installed: a reply anywhere renews it.
    case claudeStaleUntilReply
    case openCodeDisconnected
    case openCodeNotSignedIn
    case openCodeKeyRefused
    case openCodeUnreachable
    case openCodeAnswerNotUnderstood
    /// Not a failure: the windows are read, but the plan's month is used up,
    /// so OpenCode refuses work however green they are.
    case openCodeMonthlyLimitReached(until: Date?)
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
            "Codex answered in a form CapaTheNotch cannot read. Update CapaTheNotch."
        case let .providerCouldNotRead(detail):
            "Codex could not read its Capacity — \(detail.hasSuffix(".") ? detail : detail + ".") Retrying."
        case .codexDisconnected:
            "Turn on Codex in Settings to read its Capacity."
        case .claudeDisconnected:
            "Turn on Claude Code in Settings to read its Capacity."
        case .claudeStatusLineStale:
            "Run Claude Code in a terminal to update its last published Capacity."
        case .claudeStatusLineUnavailable:
            "Claude Code's Capacity appears after your next message in Claude Code in a terminal."
        case .claudeStaleUntilReply:
            "Updates after Claude's next reply — in the desktop app, VS Code or a terminal."
        case let .claudeNextReply(lastReadAt, anyReply):
            Localization.format(Self.nextReply(lastReadAt: lastReadAt, anyReply: anyReply), lastReadAt.map { Self.age(of: $0, now: Date(), in: .english) } ?? "", in: .english)
        case .openCodeDisconnected:
            "Turn on OpenCode in Settings to read its Capacity."
        case .openCodeNotSignedIn:
            "Sign in to OpenCode with `opencode auth login`, then try again."
        case .openCodeKeyRefused:
            "OpenCode refused its key. Sign in again with `opencode auth login`."
        case .openCodeUnreachable:
            "opencode.ai is not answering. Retrying."
        case .openCodeAnswerNotUnderstood:
            "OpenCode's answer was not understood. Update CapaTheNotch."
        case .openCodeMonthlyLimitReached:
            "Monthly limit reached"
        case .staleFromArchive:
            "Last seen before CapaTheNotch restarted. Refreshing."
        }
    }

    /// The guidance in the language Settings speak. A Provider's own detail
    /// stays as it came: it is the Provider's words, not ours to translate.
    public var localizedGuidance: String { localizedGuidance(at: Date()) }

    /// The guidance as of `now`, for a reason that says how old something is.
    public func localizedGuidance(at now: Date) -> String {
        switch self {
        case let .claudeNextReply(lastReadAt?, anyReply):
            Localization.format(Self.nextReply(lastReadAt: lastReadAt, anyReply: anyReply), Self.age(of: lastReadAt, now: now))
        case let .claudeNextReply(nil, anyReply):
            Localization.text(Self.nextReply(lastReadAt: nil, anyReply: anyReply))
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

    private static func nextReply(lastReadAt: Date?, anyReply: Bool) -> String {
        switch (lastReadAt != nil, anyReply) {
        case (true, true): "Updates after Claude's next reply · read %@"
        case (true, false): "Updates after your next message in Claude Code in a terminal · read %@"
        case (false, true): "Claude Code's Capacity appears after Claude's next reply."
        case (false, false): "Claude Code's Capacity appears after your next message in Claude Code in a terminal."
        }
    }

    /// How long ago, as the cards say it: "2 hours ago", "2 ч назад".
    public static func age(of date: Date, now: Date, in language: AppLanguage = Localization.current) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return Localization.text("just now", in: language) }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = language.locale
        formatter.unitsStyle = language.resolved() == .russian ? .short : .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Whether the card's chip already carries this, so spelling it out in a
    /// sentence underneath would only repeat it.
    public var repeatsTheChip: Bool {
        switch self {
        case .staleFromArchive, .openCodeMonthlyLimitReached: true
        default: false
        }
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
        case .claudeNextReply: "claude-next-reply"
        case .claudeStaleUntilReply: "claude-stale-until-reply"
        case .openCodeDisconnected: "opencode-disconnected"
        case .openCodeNotSignedIn: "opencode-not-signed-in"
        case .openCodeKeyRefused: "opencode-key-refused"
        case .openCodeUnreachable: "opencode-unreachable"
        case .openCodeAnswerNotUnderstood: "opencode-not-understood"
        case .openCodeMonthlyLimitReached: "opencode-month-used-up"
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
             .claudeNextReply,
             .openCodeNotSignedIn,
             .openCodeKeyRefused,
             .openCodeAnswerNotUnderstood:
            true
        case .providerUnavailable,
             .providerCouldNotRead,
             .codexDisconnected,
             .claudeDisconnected,
             .claudeStatusLineStale,
             .claudeStaleUntilReply,
             .openCodeDisconnected,
             .openCodeUnreachable,
             .openCodeMonthlyLimitReached,
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
             .claudeStaleUntilReply,
             .claudeNextReply,
             .openCodeUnreachable,
             .staleFromArchive:
            true
        case .openCodeDisconnected,
             .openCodeNotSignedIn,
             .openCodeKeyRefused,
             .openCodeAnswerNotUnderstood,
             .openCodeMonthlyLimitReached,
             .providerNotInstalled,
             .providerIncompatible,
             .providerNotAuthenticated,
             .providerAnswerNotUnderstood,
             .codexDisconnected,
             .claudeDisconnected,
             .claudeStatusLineUnavailable:
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
    /// A window known to have reset at this moment and not used since as
    /// far as the Provider has said: whole, with no next reset to show.
    public let cameBackAt: Date?

    public init(
        id: String,
        label: String,
        durationMinutes: Int? = nil,
        usedFraction: Double,
        resetsAt: Date?,
        cameBackAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.durationMinutes = durationMinutes
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.cameBackAt = cameBackAt
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

/// One place for a gauge on a Provider's card: a window as read, or one the
/// Provider is known to keep that was not sent this time.
public enum GaugeSlot: Equatable, Sendable {
    case read(QuotaWindow)
    /// Kept in its place, saying there is no data, rather than left out or
    /// guessed at.
    case missing(label: String)

    /// The windows Claude Code always has, a five-hour one and a week; each
    /// of its sessions sends only those it saw used, so one may be missing.
    static let claudeCodeWindows: [(label: String, durationMinutes: Int)] = [("5 hour", 300), ("Weekly", 10_080)]

    public static func slots(for snapshot: CapacitySnapshot) -> [GaugeSlot] {
        guard snapshot.provider == .claudeCode, !snapshot.windows.isEmpty else {
            return snapshot.windows.map(GaugeSlot.read)
        }
        return claudeCodeWindows.map { expected in
            snapshot.windows.first { $0.durationMinutes == expected.durationMinutes }
                .map(GaugeSlot.read) ?? .missing(label: expected.label)
        }
    }
}

