import Foundation

/// The subset of the Codex App Server protocol that CapaTheNotch speaks.
///
/// CapaTheNotch only reads. It never calls a login, logout, or token method,
/// so it cannot copy, persist, or refresh Codex credentials even by accident.
public enum CodexAppServerMethod {
    public static let initialize = "initialize"
    public static let initialized = "initialized"
    public static let readAccount = "account/read"
    public static let readRateLimits = "account/rateLimits/read"
    public static let rateLimitsUpdated = "account/rateLimits/updated"

    /// Every method this client is allowed to send. Anything outside this list
    /// would move CapaTheNotch beyond reading Capacity.
    public static let permittedOutbound: Set<String> = [
        initialize,
        initialized,
        readAccount,
        readRateLimits,
    ]
}

public struct CodexClientInfo: Sendable {
    public let name: String
    public let version: String

    public init(name: String = "capacity_notch", version: String) {
        self.name = name
        self.version = version
    }

    public var initializeParams: [String: Any] {
        ["clientInfo": ["name": name, "version": version]]
    }
}

/// `GetAccountResponse` — only the fields CapaTheNotch needs.
///
/// `requiresOpenaiAuth` is decoded though nothing reads it, because it is the
/// one field the App Server's own schema requires. `account` may be absent
/// when nobody is signed in, so its absence says nothing; an answer without
/// `requiresOpenaiAuth` is not one this build understands, and is not read as
/// a signed-out Codex.
public struct CodexAccountResponse: Decodable, Equatable, Sendable {
    public struct Account: Decodable, Equatable, Sendable {}

    public let account: Account?
    public let requiresOpenaiAuth: Bool

    public var isAuthenticated: Bool { account != nil }
}

/// `RateLimitWindow`: `usedPercent` is whole percent, `resetsAt` unix seconds.
public struct CodexRateLimitWindow: Decodable, Equatable, Sendable {
    public let usedPercent: Int
    public let windowDurationMins: Int?
    public let resetsAt: Int?

    public init(usedPercent: Int, windowDurationMins: Int?, resetsAt: Int?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

/// `RateLimitSnapshot`, carried by both the read response and the rolling update.
public struct CodexRateLimitSnapshot: Decodable, Equatable, Sendable {
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?

    public init(primary: CodexRateLimitWindow?, secondary: CodexRateLimitWindow?) {
        self.primary = primary
        self.secondary = secondary
    }
}

/// `GetAccountRateLimitsResponse` — the single-bucket view CapaTheNotch reads.
public struct CodexRateLimitsResponse: Decodable, Equatable, Sendable {
    public let rateLimits: CodexRateLimitSnapshot
}

/// `AccountRateLimitsUpdatedNotification`, a sparse rolling update.
public struct CodexRateLimitsUpdatedNotification: Decodable, Equatable, Sendable {
    public let rateLimits: CodexRateLimitSnapshot
}
