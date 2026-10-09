import CryptoKit
import Foundation

public enum ClaudeStatusLineBridgeError: Error, Equatable, Sendable {
    case missingSnapshot
    case missingRateLimits
    case malformedInput
    case unsupportedSchema
}

public struct ClaudeCapacityReading: Equatable, Sendable {
    /// How long a reading counts as Fresh Capacity, counted from after it was
    /// taken, so a status line that keeps running never goes stale between
    /// runs.
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
    private let now: @Sendable () -> Date

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    /// The two windows Claude Code reports, in the order they are shown.
    private static let official: [(id: String, label: String, durationMinutes: Int)] = [
        ("five_hour", "5 hour", 300),
        ("seven_day", "Weekly", 10_080),
    ]

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

        // Claude Code drops a window once its reset has passed; a file
        // written before a reset still holds the old one. Either way that
        // window is not known now — another session may have begun a new
        // one — so it is left out, and the card says there is no data.
        let now = now().timeIntervalSince1970
        let windows = Self.official.compactMap { official -> QuotaWindow? in
            guard let stored = snapshot.windows.first(where: { $0.id == official.id }), stored.resetsAt > now else {
                // Seen, then past its reset, and none sent since: whole, as
                // far as Claude Code has said.
                guard let back = snapshot.cameBack?.first(where: { $0.id == official.id })?.at, back <= now else { return nil }
                return QuotaWindow(
                    id: "claude-\(official.id.replacingOccurrences(of: "_", with: "-"))",
                    label: official.label,
                    durationMinutes: official.durationMinutes,
                    usedFraction: 0,
                    resetsAt: nil,
                    cameBackAt: Date(timeIntervalSince1970: back)
                )
            }
            return QuotaWindow(
                id: "claude-\(official.id.replacingOccurrences(of: "_", with: "-"))",
                label: official.label,
                durationMinutes: official.durationMinutes,
                usedFraction: min(max(stored.usedPercentage / 100, 0), 1),
                resetsAt: Date(timeIntervalSince1970: stored.resetsAt)
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
        let cameBack: [ClaudeStatusLineBridge.CameBack]?
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
    /// when it reads; the card says only that Capacity has not arrived, and a
    /// report needs to know which way it failed.
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

        var incoming: [PublishedWindow] = []
        if let fiveHour = input.rateLimits?.fiveHour {
            incoming.append(PublishedWindow(id: "five_hour", source: fiveHour))
        }
        if let sevenDay = input.rateLimits?.sevenDay {
            incoming.append(PublishedWindow(id: "seven_day", source: sevenDay))
        }
        guard !incoming.isEmpty else {
            throw ClaudeStatusLineBridgeError.missingRateLimits
        }
        let now = capturedAt.timeIntervalSince1970
        let sessions = record(incoming, from: session(input.sessionId), into: published(at: destination)?.sessions ?? [], at: now)

        let windows = believed(sessions, at: now)
        let snapshot = PublishedSnapshot(
            schemaVersion: 1,
            capturedAt: now,
            windows: windows,
            sessions: sessions,
            cameBack: cameBack(sessions, believed: windows, at: now)
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
        let sessionId: String?
        let rateLimits: RateLimits?

        private enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
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

    /// Every open Claude Code session runs the bridge, each with the limits
    /// as its own last request saw them, and the last to write would win:
    /// a session idle since the week began undid a busy one every minute.
    /// A session's limits change only when it has just asked, so for each
    /// window the session that saw it change last is believed — an idle one
    /// repeating itself never is, and a share that falls after a plan grows
    /// is shown at once. Each session is told apart by a digest of its id,
    /// from which the id cannot be had back.
    private static func session(_ id: String?) -> String {
        let digest = SHA256.hash(data: Data((id ?? "").utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The sessions as they now stand: this one's windows, each with when
    /// it last changed, and the others as they were — those not heard from
    /// in a week, or past the last 32, forgotten.
    private static func record(_ incoming: [PublishedWindow], from id: String, into held: [StoredSession], at now: Double) -> [StoredSession] {
        let before = held.first { $0.id == id }
        let sent = incoming.map { new -> SessionWindow in
            let old = before?.windows.first { $0.id == new.id }
            let same = old.map { $0.usedPercentage == new.usedPercentage && $0.resetsAt == new.resetsAt } ?? false
            return SessionWindow(id: new.id, usedPercentage: new.usedPercentage, resetsAt: new.resetsAt, changedAt: same ? old!.changedAt : now)
        }
        // A window Claude Code stopped sending — dropped once its reset
        // passed — is kept, so when it came back is known.
        let kept = (before?.windows ?? []).filter { old in !sent.contains { $0.id == old.id } }
        let windows = sent + kept
        let others = held.filter { $0.id != id && now - $0.seenAt < 7 * 86_400 }
        let sessions = others + [StoredSession(id: id, seenAt: now, windows: windows)]
        return Array(sessions.sorted { $0.seenAt > $1.seenAt }.prefix(32))
    }

    /// For each window, as the session that saw it change last saw it, while
    /// its reset is still ahead.
    private static func believed(_ sessions: [StoredSession], at now: Double) -> [PublishedWindow] {
        ["five_hour", "seven_day"].compactMap { id in
            sessions
                .compactMap { $0.windows.first { $0.id == id && $0.resetsAt > now } }
                .max { $0.changedAt < $1.changedAt }
                .map { PublishedWindow(id: $0.id, usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt) }
        }
    }

    /// For each window none is believed for, the latest reset any session
    /// saw pass: the window came back whole then.
    private static func cameBack(_ sessions: [StoredSession], believed: [PublishedWindow], at now: Double) -> [CameBack]? {
        let back = ["five_hour", "seven_day"].compactMap { id -> CameBack? in
            guard !believed.contains(where: { $0.id == id }) else { return nil }
            let passed = sessions.flatMap(\.windows).filter { $0.id == id && $0.resetsAt <= now }.map(\.resetsAt)
            return passed.max().map { CameBack(id: id, at: $0) }
        }
        return back.isEmpty ? nil : back
    }

    /// What the bridge last wrote, or nothing if it cannot be read.
    private static func published(at destination: URL) -> PublishedSnapshot? {
        guard let data = try? Data(contentsOf: destination) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let snapshot = try? decoder.decode(PublishedSnapshot.self, from: data), snapshot.schemaVersion == 1 else { return nil }
        return snapshot
    }

    private struct PublishedSnapshot: Codable {
        let schemaVersion: Int
        let capturedAt: Double
        let windows: [PublishedWindow]
        /// Absent from files written before sessions were told apart.
        var sessions: [StoredSession]?
        var cameBack: [CameBack]?
    }

    struct CameBack: Codable {
        let id: String
        let at: Double
    }

    private struct StoredSession: Codable {
        /// A digest of the session's id, never the id.
        let id: String
        let seenAt: Double
        let windows: [SessionWindow]
    }

    private struct SessionWindow: Codable {
        let id: String
        let usedPercentage: Double
        let resetsAt: Double
        let changedAt: Double
    }

    private struct PublishedWindow: Codable {
        let id: String
        let usedPercentage: Double
        let resetsAt: Double

        init(id: String, usedPercentage: Double, resetsAt: Double) {
            self.id = id
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }

        init(id: String, source: SourceWindow) {
            self.id = id
            usedPercentage = source.usedPercentage
            resetsAt = source.resetsAt
        }
    }
}
