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

func aWindowClaudeCodeDoesNotSendIsNoDataNotWhole() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("claude-capacity.json")
    let now = claudeFixedNow

    // A session drops a window once its reset has passed, whatever another
    // session has used since: a window not sent is not known, not whole.
    let weekOnly = Data(
        #"{"rate_limits":{"seven_day":{"used_percentage":1,"resets_at":\#(now.timeIntervalSince1970 + 86_400)}}}"#.utf8
    )
    try ClaudeStatusLineBridge.publish(statusLineJSON: weekOnly, capturedAt: now, to: destination)
    let dropped = try ClaudeFileCapacitySource(fileURL: destination, now: { now }).read()
    try expect(dropped.windows.map(\.label) == ["Weekly"], "Only the week is read, got \(dropped.windows.map(\.label))")
    let snapshot = CapacitySnapshot(provider: .claudeCode, capturedAt: now, windows: dropped.windows, connectionState: .fresh)
    try expect(
        GaugeSlot.slots(for: snapshot) == [.missing(label: "5 hour"), .read(dropped.windows[0])],
        "and the five hours keep their place, saying there is no data, got \(GaugeSlot.slots(for: snapshot))"
    )

    // Five hours seen, then past their reset, and Claude Code drops them:
    // they came back whole at that reset, and say so, until a session sends
    // the new window.
    let resetAt = now.timeIntervalSince1970 + 60
    let both = Data(
        #"{"rate_limits":{"five_hour":{"used_percentage":80,"resets_at":\#(resetAt)},"seven_day":{"used_percentage":30,"resets_at":\#(now.timeIntervalSince1970 + 86_400)}}}"#.utf8
    )
    try ClaudeStatusLineBridge.publish(statusLineJSON: both, capturedAt: now, to: destination)
    let weekLater = Data(
        #"{"rate_limits":{"seven_day":{"used_percentage":30,"resets_at":\#(now.timeIntervalSince1970 + 86_400)}}}"#.utf8
    )
    let later = now.addingTimeInterval(120)
    try ClaudeStatusLineBridge.publish(statusLineJSON: weekLater, capturedAt: later, to: destination)
    let past = try ClaudeFileCapacitySource(fileURL: destination, now: { later }).read()
    try expect(past.windows.map(\.label) == ["5 hour", "Weekly"], "Five hours past their reset are shown, got \(past.windows.map(\.label))")
    try expect(past.windows.first?.remainingPercentage == 100, "whole")
    try expect(past.windows.first?.resetsAt == nil, "with no reset ahead known")
    try expect(past.windows.first?.cameBackAt == Date(timeIntervalSince1970: resetAt), "and when they came back")

    let codex = CapacitySnapshot(provider: .codex, capturedAt: now, windows: dropped.windows, connectionState: .fresh)
    try expect(GaugeSlot.slots(for: codex).count == 1, "Only Claude Code is held to its two windows")
}

func theSessionWhoseLimitsChangedLastIsBelieved() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("claude-capacity.json")
    let now = claudeFixedNow.timeIntervalSince1970
    let fiveEnds = now + 3 * 3600, weekEnds = now + 5 * 86_400
    var clock: TimeInterval = 0
    /// One run of the status line, from one session, a minute after the last.
    func run(_ session: String, five: Double?, week: Double?, fiveResets: Double = fiveEnds) throws {
        var limits: [String] = []
        if let five { limits.append(#""five_hour":{"used_percentage":\#(five),"resets_at":\#(fiveResets)}"#) }
        if let week { limits.append(#""seven_day":{"used_percentage":\#(week),"resets_at":\#(weekEnds)}"#) }
        let json = Data(#"{"session_id":"\#(session)","rate_limits":{\#(limits.joined(separator: ","))}}"#.utf8)
        clock += 60
        try ClaudeStatusLineBridge.publish(statusLineJSON: json, capturedAt: claudeFixedNow.addingTimeInterval(clock), to: destination)
    }
    func left() throws -> [Double] {
        let at = claudeFixedNow.addingTimeInterval(clock)
        return try ClaudeFileCapacitySource(fileURL: destination, now: { at }).read()
            .windows.map(\.remainingPercentage)
    }

    // Every open session runs the bridge each minute, each with the limits
    // as its own last request saw them; an idle one repeats itself.
    try run("idle", five: nil, week: 1)
    try run("busy", five: 42, week: 16)
    try run("idle", five: nil, week: 1)
    let first = try left()
    try expect(first == [58, 84], "An idle session repeating itself does not undo a busy one, got \(first)")

    // The plan grows: the same use is a smaller share. A share that falls
    // in a session that just asked is believed at once.
    try run("busy", five: 20, week: 7)
    try run("idle", five: nil, week: 1)
    let upgraded = try left()
    try expect(upgraded == [80, 93], "Less used after an upgrade is shown, got \(upgraded)")

    // Another session asks and sees the newest; it wins until another does.
    try run("terminal", five: 22, week: 8)
    try run("busy", five: 20, week: 7)
    let latest = try left()
    try expect(latest == [78, 92], "The last session to see a change is believed, got \(latest)")

    // The idle session's file says nothing about its identity.
    let written = try String(contentsOf: destination, encoding: .utf8)
    try expect(!written.contains("idle") && !written.contains("busy") && !written.contains("terminal"), "Session ids are not kept, got \(written)")
}

/// Claude Code cannot be asked for its limits: Refresh re-reads the file,
/// and when nothing is newer it says where the next reading comes from and
/// how old the last one is (ticket 31).
func aRefreshWithNothingNewerSaysWhereTheNextReadingComesFrom() async throws {
    let twoHoursAgo = claudeFixedNow.addingTimeInterval(-7_200)
    let older = claudeReading(capturedAt: twoHoursAgo)
    let newer = claudeReading(capturedAt: claudeFixedNow.addingTimeInterval(-10))
    let source = SequencedClaudeCapacitySource([.success(older), .success(older), .success(older), .success(newer), .success(newer)])
    let service = ClaudeCapacityService(now: { claudeFixedNow }, capacitySource: source, nextReadingFromAnyReply: { true })

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()
    let first = await iterator.next()
    try expect(first?.statusReason == .claudeStaleUntilReply, "An old reading with the mod says a reply anywhere renews it, got \(String(describing: first?.statusReason))")

    await service.refresh(asked: true)
    let asked = await iterator.next()
    try expect(
        asked?.statusReason == .claudeNextReply(lastReadAt: twoHoursAgo, anyReply: true),
        "Nothing newer: the next reply, and when the last reading was, got \(String(describing: asked?.statusReason))"
    )
    try expect(asked?.windows == older.windows && asked?.connectionState == .stale, "with the reading as it was")

    await service.refresh()
    let unasked = await iterator.next()
    try expect(unasked?.statusReason == .claudeStaleUntilReply, "A refresh nobody asked for says nothing more")

    await service.refresh(asked: true)
    let fresh = await iterator.next()
    try expect(fresh?.connectionState == .fresh && fresh?.statusReason == nil, "A newer reading is simply shown")

    await service.refresh(asked: true)
    let same = await iterator.next()
    try expect(
        same?.connectionState == .fresh && same?.statusReason == .claudeNextReply(lastReadAt: newer.capturedAt, anyReply: true),
        "Fresh, and still nothing newer: said too"
    )
}

func whereTheNextReadingComesFromIsSaidInBothLanguages() throws {
    let now = claudeFixedNow
    let reason = CapacityStatusReason.claudeNextReply(lastReadAt: now.addingTimeInterval(-7_200), anyReply: true)
    let before = Localization.current
    defer { Localization.current = before }

    Localization.current = .russian
    let russian = reason.localizedGuidance(at: now)
    try expect(russian == "Обновится после следующего ответа Claude · данные 2 ч назад", "Russian, got \(russian)")
    Localization.current = .english
    let english = reason.localizedGuidance(at: now)
    try expect(english == "Updates after Claude's next reply · read 2 hours ago", "English, got \(english)")
    let terminal = CapacityStatusReason.claudeNextReply(lastReadAt: now.addingTimeInterval(-30), anyReply: false).localizedGuidance(at: now)
    try expect(terminal == "Updates after your next message in Claude Code in a terminal · read just now", "Without the mod, a terminal, got \(terminal)")
    try expect(
        CapacityStatusReason.claudeNextReply(lastReadAt: nil, anyReply: true).localizedGuidance(at: now) == "Claude Code's Capacity appears after Claude's next reply.",
        "Nothing read yet, with the mod"
    )
}

func withTheModNoReadingYetWaitsForAnyReply() async throws {
    let service = ClaudeCapacityService(now: { claudeFixedNow }, capacitySource: MissingClaudeCapacitySource(), nextReadingFromAnyReply: { true })
    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()
    let snapshot = await iterator.next()
    try expect(
        snapshot?.connectionState == .disconnected(.claudeNextReply(lastReadAt: nil, anyReply: true)),
        "Nothing published yet: a reply anywhere brings it, got \(String(describing: snapshot?.connectionState))"
    )
    try expect(snapshot?.statusReason?.needsAPersonFirst == true, "and Connect cannot help, so the card says it in words")
}
