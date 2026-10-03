import AppKit
import CapacityNotchCore
import Combine
import Foundation

/// The Music Module's reader: mediaremote-adapter's `stream`, run by
/// `/usr/bin/perl` from inside the application bundle (ADR 0004).
///
/// Starting asks the adapter's own `test` first, because a MediaRemote that
/// has been closed reports exactly what an idle one does — nothing playing —
/// and the two must not look alike. A stream that ends on its own is tested
/// again before it is restarted, so a crash is not mistaken for a closed door.
/// A test that fails is tried again a minute later, and on waking: one failure
/// — a Mac just woken, mediaremoted restarting — must not close the Module
/// until it is switched off and on.
@MainActor
final class MusicReader: ObservableObject {
    /// What the compact strip's row shows: playing, or paused for less than
    /// ten seconds.
    @Published private(set) var shown: NowPlaying?
    /// What is loaded, however long it has been paused: the expanded
    /// surface's page exists while this does.
    @Published private(set) var loaded: NowPlaying?
    /// The last track, once nothing is loaded: the page shows it dimmed.
    @Published private(set) var remembered: RememberedTrack?
    /// macOS stopped telling the adapter what is playing.
    @Published private(set) var isUnreadable = false
    /// The Module is on: its page is there, whether or not anything plays.
    @Published private(set) var isOn = false

    private let adapter: Adapter?
    private var presence = MusicPresence()
    private var streamFollower = NowPlayingStream()
    private var process: Process?
    private var isRunning = false
    private var lingerTimer: Timer?
    private var retryTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private static let retryAfter: TimeInterval = 60

    init(bundle: Bundle = .main) {
        adapter = Adapter(bundle: bundle)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isOn = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryIfUnreadable() }
        }
        testThenStream()
    }

    func stop() {
        isRunning = false
        isOn = false
        retryTimer?.invalidate()
        retryTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        process?.terminate()
        process = nil
        presence.forget()
        streamFollower = NowPlayingStream()
        publish()
    }

    /// Runs a control. Fire and forget: the stream reports what it changed.
    func send(_ command: MusicCommand) {
        guard let adapter, isRunning, !isUnreadable else { return }
        let arguments = adapter.arguments(command.arguments)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Adapter.run(arguments, timeout: 10)
        }
    }

    // MARK: - Reading

    private func testThenStream() {
        guard let adapter else {
            isUnreadable = true
            return
        }

        let testArguments = adapter.testArguments()
        let environment = adapter.testEnvironment()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = Adapter.run(testArguments, environment: environment, timeout: 20)
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                guard status == 0 else {
                    self.isUnreadable = true
                    self.presence.lose()
                    self.publish()
                    self.scheduleRetry()
                    return
                }
                self.isUnreadable = false
                self.startStream(adapter)
            }
        }
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        let timer = Timer(timeInterval: Self.retryAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryIfUnreadable() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func retryIfUnreadable() {
        guard isRunning, isUnreadable, process == nil else { return }
        retryTimer?.invalidate()
        retryTimer = nil
        testThenStream()
    }

    private func startStream(_ adapter: Adapter) {
        adapter.stopOrphanedStreams()
        let process = Process()
        process.executableURL = Adapter.perl
        process.arguments = adapter.arguments(["stream"])
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let output = Pipe()
        process.standardOutput = output
        let lines = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let complete = lines.append(data)
            guard !complete.isEmpty else { return }
            DispatchQueue.main.async { self?.apply(complete) }
        }

        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.isRunning, self.process === ended else { return }
                self.process = nil
                self.presence.lose()
                self.streamFollower = NowPlayingStream()
                self.publish()
                // Tested again rather than restarted blind: a stream that
                // ends because MediaRemote closed must say so.
                self.testThenStream()
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            isUnreadable = true
        }
    }

    private func apply(_ lines: [String]) {
        guard isRunning else { return }
        let now = Date()
        for line in lines {
            guard let reading = streamFollower.apply(line) else { continue }
            presence.observe(reading, at: now)
        }
        publish()
    }

    private func publish() {
        let now = Date()
        let shownNow = presence.shown(at: now)
        if shown != shownNow { shown = shownNow }
        let loadedNow = presence.loaded(at: now)
        if loaded != loadedNow { loaded = loadedNow }
        let rememberedNow = presence.remembered(at: now)
        if remembered != rememberedNow { remembered = rememberedNow }

        // A paused row goes away ten seconds after the pause, and a track
        // reported gone goes once the grace is over, whether or not the
        // stream says anything more in between.
        let lingering = (shownNow.map { !$0.isPlaying } ?? false) || presence.isHolding(at: now)
        if lingering, lingerTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            }
            RunLoop.main.add(timer, forMode: .common)
            lingerTimer = timer
        } else if !lingering {
            lingerTimer?.invalidate()
            lingerTimer = nil
        }
    }
}

/// Where the adapter's pieces sit inside the bundle, and how it is run.
private struct Adapter: Sendable {
    static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    let script: URL
    let framework: URL
    let testClient: URL

    init?(bundle: Bundle) {
        let contents = bundle.bundleURL.appendingPathComponent("Contents")
        let script = contents.appendingPathComponent("Resources/mediaremote-adapter.pl")
        let framework = contents.appendingPathComponent("Frameworks/MediaRemoteAdapter.framework")
        let testClient = contents.appendingPathComponent("Helpers/MediaRemoteAdapterTestClient")
        let files = FileManager.default
        guard
            files.fileExists(atPath: script.path),
            files.fileExists(atPath: framework.path),
            files.fileExists(atPath: testClient.path)
        else { return nil }
        self.script = script
        self.framework = framework
        self.testClient = testClient
    }

    func arguments(_ function: [String]) -> [String] {
        [script.path, framework.path] + function
    }

    func testArguments() -> [String] {
        [script.path, framework.path, testClient.path, "test"]
    }

    func testEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["MEDIAREMOTEADAPTER_TEST_CLIENT_PATH"] = testClient.path
        return environment
    }

    /// Streams this bundle's adapter left behind: parented to launchd, which
    /// is what becomes of a child whose application was killed rather than
    /// quit. Each would otherwise stay, reading, for as long as the Mac is on.
    func stopOrphanedStreams() {
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/bin/ps")
        listing.arguments = ["-A", "-o", "pid=,ppid=,command="]
        let output = Pipe()
        listing.standardOutput = output
        listing.standardError = FileHandle.nullDevice
        guard (try? listing.run()) != nil else { return }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        listing.waitUntilExit()

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard
                fields.count == 3,
                let pid = pid_t(fields[0]), let parent = pid_t(fields[1]), parent == 1,
                fields[2].contains(script.path), fields[2].hasSuffix(" stream")
            else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// Runs perl to completion, or gives up at the timeout; the exit status,
    /// or nil when it could not be run or did not finish.
    static func run(
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) -> Int32? {
        let process = Process()
        process.executableURL = perl
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }
}

/// Splits what arrives on a pipe into whole lines, keeping a partial one for
/// the next read. Lines can be long — artwork travels inside them.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex ..< newline]
                pending.removeSubrange(pending.startIndex ... newline)
                if let text = String(data: line, encoding: .utf8) { lines.append(text) }
            }
            return lines
        }
    }
}
