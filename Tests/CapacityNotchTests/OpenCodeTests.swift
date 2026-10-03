import CapacityNotchCore
import Foundation

private let openCodeNow = Date(timeIntervalSince1970: 1_800_000_000)

/// OpenCode Go's usage, shaped as `GET opencode.ai/zen/go/v1/usage` answers.
private func usage(
    rolling: (String, Int) = ("ok", 12),
    weekly: (String, Int) = ("ok", 39),
    monthly: (String, Int) = ("ok", 19)
) -> Data {
    func window(_ value: (String, Int), _ resets: String) -> String {
        #"{"status":"\#(value.0)","percent":\#(value.1),"resetsAt":"\#(resets)"}"#
    }
    return Data(#"{"usage":{"rolling":\#(window(rolling, "2027-01-15T10:20:00Z")),"weekly":\#(window(weekly, "2027-01-18T00:00:00Z")),"monthly":\#(window(monthly, "2027-02-01T00:00:00Z"))}}"#.utf8)
}

private final class FakeOpenCodeClient: OpenCodeUsageClient, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<(status: Int, body: Data), Error>]
    private(set) var keysAsked: [String] = []

    init(_ answers: [Result<(status: Int, body: Data), Error>]) { self.answers = answers }

    func usage(key: String) async throws -> (status: Int, body: Data) {
        let next: Result<(status: Int, body: Data), Error> = lock.withLock {
            keysAsked.append(key)
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
        return try next.get()
    }

    var requests: Int { lock.withLock { keysAsked.count } }
}

private func service(
    key: String? = "go-key",
    _ answers: [Result<(status: Int, body: Data), Error>],
    now: @escaping @Sendable () -> Date = { openCodeNow }
) -> (OpenCodeCapacityService, FakeOpenCodeClient) {
    let client = FakeOpenCodeClient(answers)
    return (OpenCodeCapacityService(now: now, readKey: { key }, client: client), client)
}

private func first(_ service: OpenCodeCapacityService, after: () async -> Void) async throws -> CapacitySnapshot {
    var iterator = service.snapshots.makeAsyncIterator()
    await after()
    guard let snapshot = await iterator.next() else { throw TestFailure(description: "A snapshot is published") }
    return snapshot
}

func openCodesRollingAndWeeklyAreItsTwoWindows() async throws {
    let (opencode, _) = service([.success((200, usage()))])
    let snapshot = try await first(opencode) { await opencode.connect() }
    try expect(snapshot.provider == .openCode && snapshot.connectionState == .fresh, "Fresh OpenCode Capacity, got \(snapshot)")
    try expect(snapshot.windows.map(\.label) == ["5 hour", "Weekly"], "Rolling is the five hours, weekly the week; no month")
    try expect(snapshot.windows.map(\.usedFraction) == [0.12, 0.39], "The percent is what is used")
    try expect(snapshot.windows.map(\.durationMinutes) == [300, 10_080], "Their lengths, for the strip's choice")
    try expect(
        snapshot.windows.first?.resetsAt == ISO8601DateFormatter().date(from: "2027-01-15T10:20:00Z"),
        "And when each comes back"
    )
    try expect(snapshot.statusReason == nil, "Nothing to say while the month has room")
}

func aRateLimitedWindowHasNothingLeft() async throws {
    let (opencode, _) = service([.success((200, usage(rolling: ("rate-limited", 64))))])
    let snapshot = try await first(opencode) { await opencode.connect() }
    try expect(snapshot.windows.first?.usedFraction == 1, "Rate-limited is used up, whatever its percent says")
}

func aMonthUsedUpIsSaidOverGreenWindows() async throws {
    let (opencode, _) = service([.success((200, usage(monthly: ("rate-limited", 100))))])
    let snapshot = try await first(opencode) { await opencode.connect() }
    try expect(snapshot.connectionState == .fresh, "The windows are still read")
    try expect(
        snapshot.statusReason == .openCodeMonthlyLimitReached(until: ISO8601DateFormatter().date(from: "2027-02-01T00:00:00Z")),
        "The month is said, with when it comes back, got \(String(describing: snapshot.statusReason))"
    )
    let (full, _) = service([.success((200, usage(monthly: ("ok", 100))))])
    let used = try await first(full) { await full.connect() }
    try expect(used.statusReason?.diagnosticCode == "opencode-month-used-up", "A month at 100% is used up too")
}

func eachWayOpenCodeCannotBeReadSaysWhatToDo() async throws {
    let cases: [(String?, Result<(status: Int, body: Data), Error>, CapacityStatusReason)] = [
        (nil, .success((200, usage())), .openCodeNotSignedIn),
        ("go-key", .success((401, Data())), .openCodeKeyRefused),
        ("go-key", .success((403, Data())), .openCodeKeyRefused),
        ("go-key", .failure(URLError(.notConnectedToInternet)), .openCodeUnreachable),
        ("go-key", .success((503, Data())), .openCodeUnreachable),
        ("go-key", .success((200, Data(#"{"usage":{"hourly":{}}}"#.utf8))), .openCodeAnswerNotUnderstood),
    ]
    for (key, answer, reason) in cases {
        let (opencode, client) = service(key: key, [answer])
        let snapshot = try await first(opencode) { await opencode.connect() }
        try expect(snapshot.statusReason == reason, "Expected \(reason), got \(String(describing: snapshot.statusReason))")
        try expect(snapshot.windows.isEmpty, "Nothing read is never drawn as zero")
        if key == nil { try expect(client.requests == 0, "Without a key nothing is sent") }
    }
    try expect(CapacityStatusReason.openCodeNotSignedIn.guidance.contains("opencode auth login"), "The one command that signs in")
}

func onlyTheGoKeyIsTakenFromOpenCodesOwnFile() throws {
    let file = Data(#"{"anthropic":{"type":"oauth","access":"other"},"opencode-go":{"type":"api","key":"go-key"}}"#.utf8)
    try expect(OpenCodeAuth.key(in: file) == "go-key", "The Go plan's key")
    let zen = Data(#"{"opencode":{"type":"api","key":"zen-key"}}"#.utf8)
    try expect(OpenCodeAuth.key(in: zen) == nil, "Only the Go key: another of OpenCode's entries is not taken")
    try expect(OpenCodeAuth.key(in: Data("{}".utf8)) == nil, "No OpenCode entry, no key")
    try expect(OpenCodeAuth.key(in: Data("not json".utf8)) == nil, "A file it cannot read, no key")
    try expect(
        OpenCodeAuth.defaultFileURL.path.hasSuffix("/.local/share/opencode/auth.json"),
        "OpenCode's own file, got \(OpenCodeAuth.defaultFileURL.path)"
    )
    try expect(OpenCodeUsageEndpoint.url.absoluteString == "https://opencode.ai/zen/go/v1/usage", "The one address")
}

func openCodeIsAskedAtMostEveryFiveMinutesUnlessAPersonAsks() async throws {
    final class Clock: @unchecked Sendable { var now = openCodeNow }
    let clock = Clock()
    let (opencode, client) = service([.success((200, usage()))], now: { clock.now })
    var iterator = opencode.snapshots.makeAsyncIterator()
    await opencode.connect()
    _ = await iterator.next()
    clock.now = openCodeNow.addingTimeInterval(60)
    await opencode.refresh()
    try expect(client.requests == 1, "A minute later the last answer stands")
    await opencode.refresh(force: true)
    _ = await iterator.next()
    try expect(client.requests == 2, "A person asking is asked at once")
    clock.now = openCodeNow.addingTimeInterval(60 + 301)
    await opencode.refresh()
    _ = await iterator.next()
    try expect(client.requests == 3, "Five minutes on, asked again")
}

func aFailureAfterAReadingKeepsItAsStale() async throws {
    let (opencode, _) = service([.success((200, usage())), .failure(URLError(.timedOut))])
    var iterator = opencode.snapshots.makeAsyncIterator()
    await opencode.connect()
    _ = await iterator.next()
    await opencode.refresh(force: true)
    guard let held = await iterator.next() else { throw TestFailure(description: "A failed refresh still publishes") }
    try expect(held.connectionState == .stale && held.windows.count == 2, "The last windows, marked stale")
    try expect(held.statusReason == .openCodeUnreachable, "With why")
    await opencode.disconnect()
    guard let off = await iterator.next() else { throw TestFailure(description: "Disconnecting publishes") }
    try expect(off.isSwitchedOff && off.windows.isEmpty, "Switched off, its numbers go with it")
}
