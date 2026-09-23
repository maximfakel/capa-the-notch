import Foundation

public enum ClaudeUsageCommandError: Error, Equatable, Sendable {
    case claudeCodeNotInstalled
    case commandFailed
    case outputNotUnderstood
}

/// Asks Claude Code for its own usage.
///
/// `/usage` is a local command: it sends no prompt to the model. Claude Code
/// makes the request with the credential it already holds, so Capacity Notch
/// reads no credential and speaks to nothing but the binary. This is the only
/// source that does not depend on where the person works, because Capacity
/// Notch runs it rather than waiting to be handed something.
public struct ClaudeUsageCommandSource: ClaudeCapacitySource, Sendable {
    public typealias Report = @Sendable () throws -> String

    /// Flags adapted from `vinzdg/codenotch` (MIT, see `THIRD_PARTY_NOTICES`).
    /// `--print` avoids the workspace-trust prompt an interactive run can
    /// raise, `--no-session-persistence` leaves no transcript behind, and
    /// `--strict-mcp-config` with no config given starts no MCP server at all
    /// — without it every poll would start whatever the person has configured.
    public static let arguments = [
        "--print",
        "--no-session-persistence",
        "--strict-mcp-config",
        "/usage",
    ]

    /// Long enough for a cold start on a busy machine, short enough that a
    /// wedged process cannot hold a refresh open.
    public static let timeout: TimeInterval = 20

    public static let defaultSearchPaths = [
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
    ]

    private let now: @Sendable () -> Date
    private let report: Report

    public init(now: @escaping @Sendable () -> Date = { Date() }, report: @escaping Report) {
        self.now = now
        self.report = report
    }

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        searchPaths: [String] = ClaudeUsageCommandSource.defaultSearchPaths,
        timeout: TimeInterval = ClaudeUsageCommandSource.timeout
    ) {
        self.now = now
        self.report = { try Self.run(searchPaths: searchPaths, timeout: timeout) }
    }

    public static func locate(
        searchPaths: [String] = defaultSearchPaths,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        searchPaths.first(where: isExecutable)
    }

    public func read() throws -> ClaudeCapacityReading {
        let text = try report()
        guard let reading = ClaudeUsageOutput.reading(from: text, capturedAt: now()) else {
            throw ClaudeUsageCommandError.outputNotUnderstood
        }
        return reading
    }

    /// Somewhere of Capacity Notch's own for Claude Code to be run from.
    private static func scratchDirectory() -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CapacityNotch", isDirectory: true)
            .appendingPathComponent("claude-usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func run(searchPaths: [String], timeout: TimeInterval) throws -> String {
        guard let executable = locate(searchPaths: searchPaths) else {
            throw ClaudeUsageCommandError.claudeCodeNotInstalled
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // A working directory of its own. Without one the child inherits
        // Capacity Notch's, and Claude Code reaches around whatever directory
        // it is started in — which is how a Capacity reading came to ask macOS
        // for the Documents folder. One fixed directory also means Claude Code
        // keys at most one project folder on it, rather than a fresh one per
        // reading.
        process.currentDirectoryURL = scratchDirectory()
        process.standardError = FileHandle.nullDevice

        let output = Pipe()
        process.standardOutput = output
        // Claude Code reads stdin in print mode; an empty one ends it at once.
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw ClaudeUsageCommandError.commandFailed
        }

        // The output is drained alongside the wait, never ahead of it. Reading
        // a pipe to its end waits for the process to close it, which a wedged
        // one never does, so a read that came first held the deadline off for
        // ever. Draining at all matters too: a process whose output fills the
        // pipe cannot exit until someone reads it.
        let drained = DrainedOutput(output.fileHandleForReading)

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw ClaudeUsageCommandError.commandFailed
        }

        // Gone, so what it wrote is at most a moment behind — unless something
        // it started still holds the pipe, which is not worth waiting on.
        guard
            let data = drained.data(within: 1),
            process.terminationStatus == 0,
            let text = String(data: data, encoding: .utf8)
        else {
            throw ClaudeUsageCommandError.commandFailed
        }
        return text
    }
}

/// Everything a pipe carries, read on a queue of its own.
private final class DrainedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var collected = Data()

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = handle.readDataToEndOfFile()
            lock.withLock { collected = data }
            finished.signal()
        }
    }

    func data(within seconds: TimeInterval) -> Data? {
        guard finished.wait(timeout: .now() + seconds) == .success else { return nil }
        return lock.withLock { collected }
    }
}

/// Takes whichever source has the newer reading.
///
/// The status-line bridge and `/usage` describe the same windows, so the
/// question is never which source to believe but which one saw them last.
///
/// When none has a reading, the failure passed on is the one that says what
/// to fix: `/usage`'s first, since it is the source that works wherever the
/// person is, then anything else, and last a bridge that has published
/// nothing — usually a bridge nobody set up, the normal case outside a
/// terminal.
///
/// Nor does an old reading stand in for a source that just failed. A bridge
/// last run yesterday still has yesterday's file; handing that on as if it
/// were an answer would roll the surface back a day and bury the failure that
/// says what to fix. The service keeps its own last reading for that.
public struct NewestClaudeCapacity: ClaudeCapacitySource, Sendable {
    private let sources: [any ClaudeCapacitySource]
    private let staleAfter: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        _ sources: [any ClaudeCapacitySource],
        staleAfter: TimeInterval = ClaudeCapacityReading.freshFor,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sources = sources
        self.staleAfter = staleAfter
        self.now = now
    }

    public func read() throws -> ClaudeCapacityReading {
        var readings: [ClaudeCapacityReading] = []
        var failures: [Error] = []

        for source in sources {
            do {
                readings.append(try source.read())
            } catch {
                failures.append(error)
            }
        }

        let telling = failures.first { $0 is ClaudeUsageCommandError }
            ?? failures.first { ($0 as? ClaudeStatusLineBridgeError) != .missingSnapshot }
        guard let newest = readings.max(by: { $0.capturedAt < $1.capturedAt }) else {
            throw telling ?? failures.first ?? ClaudeStatusLineBridgeError.missingSnapshot
        }
        if let telling, now().timeIntervalSince(newest.capturedAt) > staleAfter {
            throw telling
        }
        return newest
    }
}

/// Holds a source's last answer for a while.
///
/// `/usage` costs a subprocess and a couple of seconds. The surface refreshes
/// every minute, and running Claude Code that often to learn a percentage that
/// moves slowly would be rude to the machine.
public final class ThrottledCapacitySource: ClaudeCapacitySource, @unchecked Sendable {
    private let source: any ClaudeCapacitySource
    private let interval: TimeInterval
    private let failureInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var lastAttempt: Date?
    private var lastResult: Result<ClaudeCapacityReading, Error>?

    /// An answer is held for `interval`; a failure only for `failureInterval`,
    /// since holding a failure as long as an answer is what kept Claude
    /// unread for minutes after an update.
    public init(
        _ source: any ClaudeCapacitySource,
        interval: TimeInterval,
        failureInterval: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.interval = interval
        self.failureInterval = min(failureInterval, interval)
        self.now = now
    }

    public func read() throws -> ClaudeCapacityReading {
        lock.lock()
        let held = lastResult
        let attemptedAt = lastAttempt
        lock.unlock()

        if let held, let attemptedAt {
            let holdsFor: TimeInterval
            switch held {
            case .success: holdsFor = interval
            case .failure: holdsFor = failureInterval
            }
            if now().timeIntervalSince(attemptedAt) < holdsFor {
                return try held.get()
            }
        }

        let result = Result { try source.read() }
        lock.lock()
        lastAttempt = now()
        lastResult = result
        lock.unlock()

        return try result.get()
    }
}
