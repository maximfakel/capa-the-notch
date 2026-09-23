import Foundation

/// What a bug report may contain.
///
/// The safety here is structural, not textual. A report is assembled from
/// closed vocabularies — enumerations, counts, dates, version strings — and no
/// Provider's own words ever reach it. A blocklist can only catch the shapes
/// somebody thought of; a report that cannot hold free text cannot leak one.
///
/// `Redaction` runs over the finished text as a second line, for the version
/// strings and paths that do come from outside.
public struct ProviderDiagnostic: Equatable, Sendable {
    public let provider: Provider
    public let connectionState: CapacityConnectionState
    public let reasonCode: String?
    public let windowCount: Int
    public let capturedAt: Date?
    public let consecutiveTransientFailures: Int

    public init(
        provider: Provider,
        connectionState: CapacityConnectionState,
        reasonCode: String?,
        windowCount: Int,
        capturedAt: Date?,
        consecutiveTransientFailures: Int
    ) {
        self.provider = provider
        self.connectionState = connectionState
        self.reasonCode = reasonCode
        self.windowCount = windowCount
        self.capturedAt = capturedAt
        self.consecutiveTransientFailures = consecutiveTransientFailures
    }

    public init(
        snapshot: CapacitySnapshot,
        consecutiveTransientFailures: Int = 0
    ) {
        self.init(
            provider: snapshot.provider,
            connectionState: snapshot.connectionState,
            reasonCode: snapshot.statusReason?.diagnosticCode,
            windowCount: snapshot.windows.count,
            capturedAt: snapshot.capturedAt,
            consecutiveTransientFailures: consecutiveTransientFailures
        )
    }
}

public struct DiagnosticReport: Sendable {
    public let applicationVersion: String
    public let systemVersion: String
    public let generatedAt: Date
    public let providers: [ProviderDiagnostic]
    /// Closed observations the application can make about itself, such as
    /// whether a bridge snapshot exists. Never a message from anywhere else.
    public let observations: [String]

    public init(
        applicationVersion: String,
        systemVersion: String,
        generatedAt: Date,
        providers: [ProviderDiagnostic],
        observations: [String] = []
    ) {
        self.applicationVersion = applicationVersion
        self.systemVersion = systemVersion
        self.generatedAt = generatedAt
        self.providers = providers
        self.observations = observations
    }

    public func text(formatter: ISO8601DateFormatter = DiagnosticReport.timestamps()) -> String {
        var lines = [
            "Capacity Notch \(applicationVersion)",
            "macOS \(systemVersion)",
            "generated \(formatter.string(from: generatedAt))",
            "",
        ]

        for provider in providers {
            lines.append("\(provider.provider.rawValue):")
            lines.append("  state \(provider.connectionState.diagnosticCode)")
            if let reason = provider.reasonCode {
                lines.append("  reason \(reason)")
            }
            lines.append("  windows \(provider.windowCount)")
            if let capturedAt = provider.capturedAt {
                lines.append("  read \(formatter.string(from: capturedAt))")
            }
            if provider.consecutiveTransientFailures > 0 {
                lines.append("  retries \(provider.consecutiveTransientFailures)")
            }
        }

        if !observations.isEmpty {
            lines.append("")
            lines.append(contentsOf: observations.map { "note \($0)" })
        }

        return Redaction.scrub(lines.joined(separator: "\n"))
    }

    public static func timestamps() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

public extension CapacityConnectionState {
    var diagnosticCode: String {
        switch self {
        case .mock: "mock"
        case .connecting: "connecting"
        case .fresh: "fresh"
        case .stale: "stale"
        case .disconnected: "disconnected"
        }
    }
}

/// The second line: anything that got in from outside is rubbed out by shape.
///
/// This is not what makes the report safe — the closed vocabulary is. This
/// catches what a version string or a path can carry, and what a future
/// careless addition might.
public enum Redaction {
    private static let patterns: [(String, String)] = [
        // A JSON Web Token, and anything else beginning the way one does.
        ("eyJ[A-Za-z0-9_.+/=-]{8,}", "[redacted-token]"),
        // Provider key shapes.
        ("sk-[A-Za-z0-9_-]{8,}", "[redacted-token]"),
        ("(?i)bearer\\s+[A-Za-z0-9._~+/=-]{8,}", "[redacted-token]"),
        // An address.
        ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "[redacted-address]"),
        // An identifier.
        ("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", "[redacted-id]"),
        // Somebody's home, and therefore their name.
        ("/Users/[^/\\s]+", "~"),
        // A long opaque run, which is what a secret looks like when it is not
        // one of the shapes above.
        ("[A-Za-z0-9_-]{32,}", "[redacted-opaque]"),
    ]

    public static func scrub(_ text: String) -> String {
        patterns.reduce(text) { partial, rule in
            guard let regex = try? NSRegularExpression(pattern: rule.0) else { return partial }
            return regex.stringByReplacingMatches(
                in: partial,
                range: NSRange(partial.startIndex..., in: partial),
                withTemplate: rule.1
            )
        }
    }
}
