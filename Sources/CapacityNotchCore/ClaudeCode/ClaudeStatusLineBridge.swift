import Foundation

public enum ClaudeStatusLineBridgeError: Error, Equatable, Sendable {
    case missingSnapshot
    case missingRateLimits
    case malformedInput
    case unsupportedSchema
}

public struct ClaudeCapacityReading: Equatable, Sendable {
    /// How long a reading counts as Fresh Capacity: as long as `/usage` is
    /// held for, which is counted from after the reading was taken, so a
    /// source that keeps answering never goes stale between answers.
    public static let freshFor: TimeInterval = 5 * 60

    public let capturedAt: Date
    public let windows: [QuotaWindow]

    public init(capturedAt: Date, windows: [QuotaWindow]) {
        self.capturedAt = capturedAt
        self.windows = windows
    }
}

public protocol ClaudeCapacitySource: Sendable {
    func read() throws -> ClaudeCapacityReading
}

public struct ClaudeFileCapacitySource: ClaudeCapacitySource, Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func read() throws -> ClaudeCapacityReading {
        guard let data = try? Data(contentsOf: fileURL) else {
            throw ClaudeStatusLineBridgeError.missingSnapshot
        }

        let snapshot: StoredSnapshot
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            snapshot = try decoder.decode(StoredSnapshot.self, from: data)
        } catch {
            throw ClaudeStatusLineBridgeError.malformedInput
        }
        guard snapshot.schemaVersion == 1 else {
            throw ClaudeStatusLineBridgeError.unsupportedSchema
        }

        let windows = snapshot.windows.compactMap { window -> QuotaWindow? in
            let presentation: (label: String, durationMinutes: Int)
            switch window.id {
            case "five_hour":
                presentation = ("5 hour", 300)
            case "seven_day":
                presentation = ("Weekly", 10_080)
            default:
                return nil
            }
            return QuotaWindow(
                id: "claude-\(window.id.replacingOccurrences(of: "_", with: "-"))",
                label: presentation.label,
                durationMinutes: presentation.durationMinutes,
                usedFraction: min(max(window.usedPercentage / 100, 0), 1),
                resetsAt: Date(timeIntervalSince1970: window.resetsAt)
            )
        }
        guard !windows.isEmpty else {
            throw ClaudeStatusLineBridgeError.missingRateLimits
        }
        return ClaudeCapacityReading(
            capturedAt: Date(timeIntervalSince1970: snapshot.capturedAt),
            windows: windows
        )
    }

    private struct StoredSnapshot: Decodable {
        let schemaVersion: Int
        let capturedAt: Double
        let windows: [StoredWindow]
    }

    private struct StoredWindow: Decodable {
        let id: String
        let usedPercentage: Double
        let resetsAt: Double
    }
}

/// Publishes only the Capacity fields Claude Code officially supplies to a
/// status-line command. Session identity, transcript paths, prompts, and
/// credentials are deliberately absent from the persisted format.
public enum ClaudeStatusLineBridge {
    public static var defaultSnapshotURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CapacityNotch", isDirectory: true)
            .appendingPathComponent("claude-capacity.json")
    }

    /// The bridge file's state as a word a bug report can carry, or nothing
    /// when it reads. On the surface a bridge that cannot be read is simply
    /// outranked by `/usage`; only a report needs to know which way it failed.
    public static func observation(of fileURL: URL = defaultSnapshotURL) -> String? {
        do {
            _ = try ClaudeFileCapacitySource(fileURL: fileURL).read()
            return nil
        } catch ClaudeStatusLineBridgeError.missingSnapshot {
            return "claude-bridge-snapshot-missing"
        } catch ClaudeStatusLineBridgeError.unsupportedSchema {
            return "claude-bridge-schema-unknown"
        } catch ClaudeStatusLineBridgeError.missingRateLimits {
            return "claude-bridge-no-windows"
        } catch {
            return "claude-bridge-unreadable"
        }
    }

    public static func publish(
        statusLineJSON: Data,
        capturedAt: Date = Date(),
        to destination: URL
    ) throws {
        let input: StatusLineInput
        do {
            input = try JSONDecoder().decode(StatusLineInput.self, from: statusLineJSON)
        } catch {
            throw ClaudeStatusLineBridgeError.malformedInput
        }

        var windows: [PublishedWindow] = []
        if let fiveHour = input.rateLimits?.fiveHour {
            windows.append(PublishedWindow(id: "five_hour", source: fiveHour))
        }
        if let sevenDay = input.rateLimits?.sevenDay {
            windows.append(PublishedWindow(id: "seven_day", source: sevenDay))
        }
        guard !windows.isEmpty else {
            throw ClaudeStatusLineBridgeError.missingRateLimits
        }

        let snapshot = PublishedSnapshot(
            schemaVersion: 1,
            capturedAt: capturedAt.timeIntervalSince1970,
            windows: windows
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
    }

    private struct StatusLineInput: Decodable {
        let rateLimits: RateLimits?

        private enum CodingKeys: String, CodingKey {
            case rateLimits = "rate_limits"
        }
    }

    private struct RateLimits: Decodable {
        let fiveHour: SourceWindow?
        let sevenDay: SourceWindow?

        private enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct SourceWindow: Decodable {
        let usedPercentage: Double
        let resetsAt: Double

        private enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    private struct PublishedSnapshot: Encodable {
        let schemaVersion: Int
        let capturedAt: Double
        let windows: [PublishedWindow]
    }

    private struct PublishedWindow: Encodable {
        let id: String
        let usedPercentage: Double
        let resetsAt: Double

        init(id: String, source: SourceWindow) {
            self.id = id
            usedPercentage = source.usedPercentage
            resetsAt = source.resetsAt
        }
    }
}
