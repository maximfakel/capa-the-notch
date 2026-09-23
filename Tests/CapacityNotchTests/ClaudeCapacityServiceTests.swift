import CapacityNotchCore
import Foundation

private let claudeFixedNow = Date(timeIntervalSince1970: 1_800_000_000)

private struct FakeClaudeCapacitySource: ClaudeCapacitySource {
    let reading: ClaudeCapacityReading

    func read() throws -> ClaudeCapacityReading {
        reading
    }
}

private struct MissingClaudeCapacitySource: ClaudeCapacitySource {
    func read() throws -> ClaudeCapacityReading {
        throw ClaudeStatusLineBridgeError.missingSnapshot
    }
}

private final class SequencedClaudeCapacitySource: ClaudeCapacitySource, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<ClaudeCapacityReading, Error>]

    init(_ results: [Result<ClaudeCapacityReading, Error>]) {
        self.results = results
    }

    func read() throws -> ClaudeCapacityReading {
        try lock.withLock {
            if results.count > 1 {
                return try results.removeFirst().get()
            }
            return try results[0].get()
        }
    }
}

private func claudeReading(capturedAt: Date = claudeFixedNow) -> ClaudeCapacityReading {
    ClaudeCapacityReading(
        capturedAt: capturedAt,
        windows: [
            QuotaWindow(
                id: "claude-five-hour",
                label: "5 hour",
                durationMinutes: 300,
                usedFraction: 0.24,
                resetsAt: claudeFixedNow.addingTimeInterval(3_600)
            ),
        ]
    )
}

func connectingClaudeReadsFreshCapacityPublishedByClaudeCode() async throws {
    let reading = claudeReading(capturedAt: claudeFixedNow.addingTimeInterval(-30))
    let service = ClaudeCapacityService(
        now: { claudeFixedNow },
        capacitySource: FakeClaudeCapacitySource(reading: reading)
    )

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()

    guard let snapshot = await iterator.next() else {
        throw TestFailure(description: "Connect should publish Claude Code Capacity")
    }
    try expect(snapshot.capturedAt == reading.capturedAt, "Freshness should use Claude Code's capture time")
    try expect(snapshot.connectionState == .fresh, "A recent bridge reading should be Fresh Capacity")
    try expect(snapshot.windows == reading.windows, "Every bridged Quota Window should reach the surface")
}

func anOldClaudeStatusLineReadingIsStaleCapacity() async throws {
    let reading = claudeReading(capturedAt: claudeFixedNow.addingTimeInterval(-301))
    let service = ClaudeCapacityService(
        now: { claudeFixedNow },
        capacitySource: FakeClaudeCapacitySource(reading: reading)
    )

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()

    guard let snapshot = await iterator.next() else {
        throw TestFailure(description: "An old bridge reading should publish a state")
    }
    try expect(snapshot.connectionState == .stale, "A bridge reading older than five minutes should be stale")
    try expect(snapshot.windows == reading.windows, "Stale Capacity should retain the last known Quota Windows")
    try expect(snapshot.statusReason == .claudeStatusLineStale, "The stale state should explain how to update it")
}

func aFailedClaudeBridgeRefreshKeepsTheLastCapacityAsStale() async throws {
    let reading = claudeReading()
    let source = SequencedClaudeCapacitySource([
        .success(reading),
        .failure(ClaudeStatusLineBridgeError.malformedInput),
    ])
    let service = ClaudeCapacityService(now: { claudeFixedNow }, capacitySource: source)

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()
    _ = await iterator.next()
    await service.refresh()

    guard let snapshot = await iterator.next() else {
        throw TestFailure(description: "A failed refresh should publish stale Capacity")
    }
    try expect(snapshot.connectionState == .stale, "A failed refresh should not erase known Capacity")
    try expect(snapshot.windows == reading.windows, "The last known Quota Windows should remain visible")
    try expect(snapshot.statusReason == .claudeStatusLineUnavailable, "The stale state should explain the failure")
}

func eachWayAskingClaudeCodeFailsSaysItsOwnFix() async throws {
    let failures: [(ClaudeUsageCommandError, CapacityStatusReason)] = [
        (.claudeCodeNotInstalled, .claudeCodeNotInstalled),
        (.commandFailed, .claudeUsageFailed),
        (.outputNotUnderstood, .claudeUsageNotUnderstood),
    ]

    for (failure, reason) in failures {
        let service = ClaudeCapacityService(
            now: { claudeFixedNow },
            capacitySource: SequencedClaudeCapacitySource([.failure(failure)])
        )

        var iterator = service.snapshots.makeAsyncIterator()
        await service.connect()

        guard let snapshot = await iterator.next() else {
            throw TestFailure(description: "A failed /usage should publish a state")
        }
        try expect(
            snapshot.connectionState == .disconnected(reason),
            "\(failure) should say \(reason), got \(snapshot.connectionState)"
        )
    }
}

private final class ClaudeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = claudeFixedNow
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

func aBridgeFromYesterdayDoesNotReplaceTheLastCapacityRead() async throws {
    let clock = ClaudeTestClock()
    let yesterday = ClaudeCapacityReading(
        capturedAt: claudeFixedNow.addingTimeInterval(-86_400),
        windows: [
            QuotaWindow(id: "claude-five-hour", label: "5 hour", durationMinutes: 300,
                        usedFraction: 0.50, resetsAt: nil),
        ]
    )
    let justNow = claudeReading(capturedAt: claudeFixedNow)
    let usage = SequencedClaudeCapacitySource([
        .success(justNow),
        .failure(ClaudeUsageCommandError.commandFailed),
    ])
    let service = ClaudeCapacityService(
        now: { clock.now },
        capacitySource: NewestClaudeCapacity(
            [FakeClaudeCapacitySource(reading: yesterday), usage],
            now: { clock.now }
        )
    )

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()
    _ = await iterator.next()

    clock.advance(6 * 60)
    await service.refresh()

    guard let snapshot = await iterator.next() else {
        throw TestFailure(description: "A failed /usage should publish a state")
    }
    try expect(snapshot.connectionState == .stale, "What was read six minutes ago is Stale Capacity")
    try expect(
        snapshot.windows == justNow.windows,
        "Stale Capacity is the last Capacity read, not a day-old bridge file; got \(snapshot.windows.map(\.usedFraction))"
    )
    try expect(
        snapshot.statusReason == .claudeUsageFailed,
        "The reason should be the failure that says what to fix, got \(String(describing: snapshot.statusReason))"
    )
}

func missingClaudeStatusLineSnapshotIsActionableAndDisconnected() async throws {
    let service = ClaudeCapacityService(
        now: { claudeFixedNow },
        capacitySource: MissingClaudeCapacitySource()
    )

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()

    guard let snapshot = await iterator.next() else {
        throw TestFailure(description: "A missing bridge snapshot should publish a state")
    }
    try expect(
        snapshot.connectionState == .disconnected(.claudeStatusLineUnavailable),
        "A missing bridge file should not look like zero Capacity"
    )
    try expect(snapshot.windows.isEmpty, "Disconnected Capacity must not contain fake zero windows")
}

func disconnectingClaudeClearsFreshCapacityFromTheSurface() async throws {
    let service = ClaudeCapacityService(
        now: { claudeFixedNow },
        capacitySource: FakeClaudeCapacitySource(reading: claudeReading())
    )

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()
    _ = await iterator.next()
    await service.disconnect()

    guard let snapshot = await iterator.next() else {
        throw TestFailure(description: "Disconnect should publish a state")
    }
    try expect(snapshot.connectionState == .disconnected(.claudeDisconnected), "Disconnect should clear Capacity")
    try expect(snapshot.windows.isEmpty, "Disconnect must remove the last known Quota Windows")
}

func publishingClaudeStatusLineWritesOnlyCapacitySnapshot() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let destination = directory.appendingPathComponent("claude-capacity.json")
    let input = Data(
        #"{"session_id":"private-session","transcript_path":"/private/transcript.jsonl","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1800003600},"seven_day":{"used_percentage":41.2,"resets_at":1800604800}}}"#.utf8
    )

    try ClaudeStatusLineBridge.publish(statusLineJSON: input, capturedAt: claudeFixedNow, to: destination)

    let publishedData = try Data(contentsOf: destination)
    let object = try JSONSerialization.jsonObject(with: publishedData)
    guard let snapshot = object as? [String: Any],
          let windows = snapshot["windows"] as? [[String: Any]]
    else {
        throw TestFailure(description: "The bridge should write a readable Capacity snapshot")
    }

    try expect(snapshot["schema_version"] as? Int == 1, "The bridge format should be versioned")
    try expect(snapshot["captured_at"] as? Double == claudeFixedNow.timeIntervalSince1970, "Capture time should survive")
    try expect(windows.compactMap { $0["id"] as? String } == ["five_hour", "seven_day"], "Both official windows should publish")
    try expect(snapshot["session_id"] == nil, "Session identity must not cross the bridge")
    try expect(snapshot["transcript_path"] == nil, "Transcript paths must not cross the bridge")
    try expect(!String(decoding: publishedData, as: UTF8.self).contains("private"), "Only Capacity may persist")
}

func fileClaudeCapacitySourceReadsPublishedQuotaWindows() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let destination = directory.appendingPathComponent("claude-capacity.json")
    let input = Data(
        #"{"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1800003600},"seven_day":{"used_percentage":41.2,"resets_at":1800604800}}}"#.utf8
    )
    try ClaudeStatusLineBridge.publish(statusLineJSON: input, capturedAt: claudeFixedNow, to: destination)

    let reading = try ClaudeFileCapacitySource(fileURL: destination).read()

    try expect(reading.capturedAt == claudeFixedNow, "The source should retain the real capture time")
    try expect(reading.windows.map(\.label) == ["5 hour", "Weekly"], "Official windows should use domain labels")
    try expect(reading.windows.map(\.remainingPercentage) == [77, 59], "Used percentage should become remaining Capacity")
}
