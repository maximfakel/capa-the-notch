import Foundation

/// A duplex line channel to one App Server.
public protocol CodexAppServerTransport: AnyObject, Sendable {
    /// One JSON-RPC message per element. The stream finishes when the App
    /// Server goes away.
    var incomingLines: AsyncStream<String> { get }

    func start() throws
    func send(line: String) throws

    /// Ends only the App Server this transport started.
    func terminate()
}

public enum CodexAppServerTransportError: Error, Equatable, Sendable {
    case notStarted
    case launchFailed(String)
}

/// Runs `codex app-server` as a child process and speaks newline-delimited
/// JSON-RPC over its standard input and output.
public final class CodexProcessTransport: CodexAppServerTransport, @unchecked Sendable {
    private let executablePath: String
    private let process = Process()
    private let inbound = Pipe()
    private let outbound = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var started = false

    public let incomingLines: AsyncStream<String>
    private let lineContinuation: AsyncStream<String>.Continuation

    private let logURL: URL?

    public init(executablePath: String, logURL: URL? = nil) {
        self.executablePath = executablePath
        self.logURL = logURL

        var capturedContinuation: AsyncStream<String>.Continuation!
        incomingLines = AsyncStream { capturedContinuation = $0 }
        lineContinuation = capturedContinuation
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server"]
        process.environment = CodexInstallation.environment()
        process.standardInput = inbound
        process.standardOutput = outbound
        // Codex logs to stderr. It is discarded unless the person running
        // CapaTheNotch asks for it by naming a file, so nothing Codex says
        // is stored behind their back.
        process.standardError = Self.log(at: logURL) ?? FileHandle.nullDevice

        outbound.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }

        do {
            try process.run()
        } catch {
            lineContinuation.finish()
            throw CodexAppServerTransportError.launchFailed(error.localizedDescription)
        }

        started = true
    }

    public func send(line: String) throws {
        lock.lock()
        let isRunning = started && process.isRunning
        lock.unlock()

        guard isRunning else { throw CodexAppServerTransportError.notStarted }
        try inbound.fileHandleForWriting.write(contentsOf: Data("\(line)\n".utf8))
    }

    public func terminate() {
        lock.lock()
        let shouldTerminate = started && process.isRunning
        started = false
        lock.unlock()

        outbound.fileHandleForReading.readabilityHandler = nil
        if shouldTerminate {
            process.terminate()
        }
        finish()
    }

    private static func log(at url: URL?) -> FileHandle? {
        let path = url?.path
            ?? ProcessInfo.processInfo.environment["CAPACITY_NOTCH_APP_SERVER_LOG"]
        guard let path, !path.isEmpty else { return nil }

        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else {
            finish()
            return
        }

        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        lock.unlock()

        for line in lines {
            lineContinuation.yield(line)
        }
    }

    private func finish() {
        lineContinuation.finish()
    }
}
