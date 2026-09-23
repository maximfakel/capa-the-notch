import CapacityNotchCore
import Combine
import Foundation

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

private func makeService(
    transport: FakeAppServerTransport
) -> CodexCapacityService {
    CodexCapacityService(
        clientInfo: CodexClientInfo(version: "0.1.0"),
        now: { fixedNow },
        makeTransport: { transport }
    )
}

private func firstSnapshot(
    from service: CodexCapacityService
) async throws -> CapacitySnapshot {
    var iterator = service.snapshots.makeAsyncIterator()
    guard let snapshot = await iterator.next() else {
        throw TestFailure(description: "The service published no Capacity Snapshot")
    }
    return snapshot
}

private func connectedTransport() -> FakeAppServerTransport {
    FakeAppServerTransport { method, id in
        switch method {
        case "initialize":
            [FakeAppServerScript.initializeResult(id: id)]
        case "account/read":
            [FakeAppServerScript.authenticatedAccount(id: id)]
        case "account/rateLimits/read":
            [FakeAppServerScript.rateLimits(id: id, primaryUsedPercent: 70, resetsAt: 1_700_003_600)]
        default:
            []
        }
    }
}

func connectingCodexPublishesFreshCapacityFromTheAppServer() async throws {
    let transport = connectedTransport()
    let service = makeService(transport: transport)

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()

    guard let snapshot = await iterator.next() else {
        throw TestFailure(description: "Connecting should publish a Capacity Snapshot")
    }

    try expect(snapshot.connectionState == .fresh, "A successful read is Fresh Capacity")
    try expect(snapshot.windows.count == 2, "Both Codex Quota Windows should reach the surface")
    try expect(
        snapshot.windows[0].remainingPercentage == 30,
        "70% used should present as 30% of Capacity left"
    )
    try expect(transport.starts == 1, "Connecting should start exactly one App Server")
}

func connectingTwiceDoesNotStartASecondAppServer() async throws {
    let transport = connectedTransport()
    let service = makeService(transport: transport)

    await service.connect()
    await service.connect()

    try expect(
        transport.starts == 1,
        "A second connect should reuse the running App Server, started \(transport.starts) times"
    )
}

func rollingUpdatesReachTheSurfaceWithoutReconnecting() async throws {
    let transport = connectedTransport()
    let service = makeService(transport: transport)

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()
    _ = await iterator.next()

    transport.push(
        FakeAppServerScript.rateLimitsUpdated(primaryUsedPercent: 90, resetsAt: 1_700_003_600)
    )

    guard let updated = await iterator.next() else {
        throw TestFailure(description: "A rolling update should publish a new Capacity Snapshot")
    }

    try expect(
        updated.windows[0].remainingPercentage == 10,
        "The updated window should show the Capacity the App Server just reported"
    )
    try expect(
        updated.windows.count == 2,
        "The window the sparse update omitted should stay on the surface"
    )
    try expect(transport.starts == 1, "Live updates must not restart the App Server")
}

func disconnectingEndsOnlyTheAppServerCapacityNotchStarted() async throws {
    let transport = connectedTransport()
    let service = makeService(transport: transport)

    await service.connect()
    try expect(transport.terminations == 0, "A connected App Server should keep running")

    await service.disconnect()

    try expect(
        transport.terminations == 1,
        "Disconnecting should end the one App Server this service started"
    )
    let stillConnected = await service.isConnected
    try expect(stillConnected == false, "Disconnecting should leave no connection")
}

func missingCodexProducesAnActionableDisconnectedState() async throws {
    let service = CodexCapacityService(
        clientInfo: CodexClientInfo(version: "0.1.0"),
        now: { fixedNow },
        makeTransport: { nil }
    )

    await service.connect()
    let snapshot = try await firstSnapshot(from: service)

    try expect(
        snapshot.connectionState == .disconnected(.providerNotInstalled),
        "A machine without Codex should report a missing installation"
    )
    try expect(
        snapshot.windows.isEmpty,
        "A missing Codex must not read as zero Capacity"
    )
}

func anIncompatibleCodexProducesAnActionableDisconnectedState() async throws {
    let transport = FakeAppServerTransport { method, id in
        method == "initialize" ? [FakeAppServerScript.methodNotFound(id: id)] : []
    }
    let service = makeService(transport: transport)

    await service.connect()
    let snapshot = try await firstSnapshot(from: service)

    guard case let .disconnected(reason) = snapshot.connectionState,
          case .providerIncompatible = reason
    else {
        throw TestFailure(description: "A rejected handshake should report an incompatible Codex")
    }
    try expect(snapshot.windows.isEmpty, "An incompatible Codex must not read as zero Capacity")
    try expect(transport.terminations == 1, "A failed handshake should end the App Server it started")
}

func anUnauthenticatedCodexProducesAnActionableDisconnectedState() async throws {
    let transport = FakeAppServerTransport { method, id in
        switch method {
        case "initialize":
            [FakeAppServerScript.initializeResult(id: id)]
        case "account/read":
            [FakeAppServerScript.signedOutAccount(id: id)]
        default:
            []
        }
    }
    let service = makeService(transport: transport)

    await service.connect()
    let snapshot = try await firstSnapshot(from: service)

    try expect(
        snapshot.connectionState == .disconnected(.providerNotAuthenticated),
        "A signed-out Codex should report that it needs a sign-in"
    )
    try expect(snapshot.windows.isEmpty, "A signed-out Codex must not read as zero Capacity")
}

func anAppServerThatStopsLeavesADisconnectedProviderNotZeroCapacity() async throws {
    let transport = connectedTransport()
    let service = makeService(transport: transport)

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()
    _ = await iterator.next()

    transport.closeConnection()

    guard let snapshot = await iterator.next() else {
        throw TestFailure(description: "A stopped App Server should publish a disconnected state")
    }
    guard case let .disconnected(reason) = snapshot.connectionState,
          case .providerUnavailable = reason
    else {
        throw TestFailure(description: "A stopped App Server should report an unavailable Provider")
    }
    try expect(snapshot.windows.isEmpty, "A stopped App Server must not read as zero Capacity")
}

func capacityNotchOnlyEverSendsCodexReadMethods() async throws {
    let transport = connectedTransport()
    let service = makeService(transport: transport)

    await service.connect()
    await service.refresh()

    let methods = transport.lines.compactMap { line -> String? in
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["method"] as? String
    }

    try expect(
        methods == [
            "initialize",
            "initialized",
            "account/read",
            "account/rateLimits/read",
            "account/rateLimits/read",
        ],
        "The handshake should read the account and its Capacity, got \(methods)"
    )
    try expect(
        methods.allSatisfy(CodexAppServerMethod.permittedOutbound.contains),
        "No method outside the read set should reach Codex"
    )
    try expect(
        methods.allSatisfy { !$0.contains("login") && !$0.contains("logout") && !$0.contains("Token") },
        "Capacity Notch must never touch a Codex credential method"
    )

    let accountRead = transport.lines.first { $0.contains("account/read") }
    try expect(
        accountRead?.contains(#""params":{}"#) == true,
        "The App Server rejects `account/read` without a params object, got \(accountRead ?? "nothing")"
    )
}

func aClientRefusesToSendAMethodOutsideTheReadSet() async throws {
    let transport = connectedTransport()
    let client = CodexAppServerClient(transport: transport)
    try await client.start()

    do {
        _ = try await client.send(method: "account/login/start")
        throw TestFailure(description: "A credential method should be refused before it is sent")
    } catch let error as CodexCapacityError {
        try expect(
            error == .methodNotPermitted("account/login/start"),
            "The refusal should name the method it blocked"
        )
    }

    try expect(
        transport.lines.isEmpty,
        "A refused method must not reach the App Server at all"
    )
}

func storeReplacesTheCapacityOfTheProviderItDescribes() throws {
    let store = CapacityNotchStore(snapshots: MockCapacityCatalog.snapshots(capturedAt: fixedNow))

    store.apply(
        CapacitySnapshot.disconnected(
            provider: .codex,
            capturedAt: fixedNow,
            reason: .providerNotInstalled
        )
    )

    try expect(
        store.snapshots.map(\.provider) == [.codex, .claudeCode],
        "Applying a snapshot should keep Providers in their display order"
    )
    try expect(
        store.snapshots[0].connectionState == .disconnected(.providerNotInstalled),
        "The Codex snapshot should carry the state just applied"
    )
    try expect(
        store.snapshots[1].connectionState == .mock,
        "Applying Codex Capacity should leave the other Provider untouched"
    )
}

func aFailedRefreshKeepsTheLastCapacityAsStale() async throws {
    let readsBeforeFailure = LockedCounter()
    let transport = FakeAppServerTransport { method, id in
        switch method {
        case "initialize":
            [FakeAppServerScript.initializeResult(id: id)]
        case "account/read":
            [FakeAppServerScript.authenticatedAccount(id: id)]
        case "account/rateLimits/read":
            readsBeforeFailure.next() == 1
                ? [FakeAppServerScript.rateLimits(
                    id: id,
                    primaryUsedPercent: 70,
                    resetsAt: 1_700_003_600
                )]
                : [#"{"id":\#(id),"error":{"code":-32603,"message":"error sending request"}}"#]
        default:
            []
        }
    }
    let service = makeService(transport: transport)

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()
    _ = await iterator.next()

    await service.refresh()

    guard let held = await iterator.next() else {
        throw TestFailure(description: "A failed refresh should still publish a Capacity Snapshot")
    }

    try expect(
        held.connectionState == .stale,
        "A backend failure should mark the last reading Stale, got \(held.connectionState)"
    )
    try expect(
        held.windows.first?.remainingPercentage == 30,
        "Stale Capacity should keep the numbers last seen, not erase them"
    )
    try expect(
        transport.terminations == 0,
        "A backend failure must not end an App Server that is still answering"
    )
    let stillConnected = await service.isConnected
    try expect(stillConnected, "A backend failure should leave the connection in place to retry")
}

func aFirstReadThatFailsHasNoCapacityToHold() async throws {
    let transport = FakeAppServerTransport { method, id in
        switch method {
        case "initialize":
            [FakeAppServerScript.initializeResult(id: id)]
        case "account/read":
            [FakeAppServerScript.authenticatedAccount(id: id)]
        case "account/rateLimits/read":
            [#"{"id":\#(id),"error":{"code":-32603,"message":"error sending request"}}"#]
        default:
            []
        }
    }
    let service = makeService(transport: transport)

    await service.connect()
    let snapshot = try await firstSnapshot(from: service)

    try expect(
        snapshot.connectionState == .disconnected(.providerCouldNotRead(detail: "error sending request")),
        "With nothing ever read there is no Stale Capacity to keep, and the reason is the error Codex gave; got \(snapshot.connectionState)"
    )
    try expect(snapshot.windows.isEmpty, "A Provider never read must not show numbers")
}

/// What a schema change in the App Server looks like: it answers, and one
/// field it used to send has a different name.
private func renamedRateLimits(id: Int) -> String {
    FakeAppServerScript.rateLimits(id: id, primaryUsedPercent: 70, resetsAt: 1_700_003_600)
        .replacingOccurrences(of: "usedPercent", with: "usedPercentage")
}

func aCodexAnswerInAShapeNotKnownKeepsTheLastCapacityAndSaysWhy() async throws {
    let reads = LockedCounter()
    let transport = FakeAppServerTransport { method, id in
        switch method {
        case "initialize":
            [FakeAppServerScript.initializeResult(id: id)]
        case "account/read":
            [FakeAppServerScript.authenticatedAccount(id: id)]
        case "account/rateLimits/read":
            reads.next() == 1
                ? [FakeAppServerScript.rateLimits(id: id, primaryUsedPercent: 70, resetsAt: 1_700_003_600)]
                : [renamedRateLimits(id: id)]
        default:
            []
        }
    }
    let service = makeService(transport: transport)

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()
    _ = await iterator.next()
    await service.refresh()

    guard let held = await iterator.next() else {
        throw TestFailure(description: "An answer Capacity Notch cannot read should still publish a state")
    }
    try expect(held.connectionState == .stale, "Codex answered, so what it said last is Stale Capacity, got \(held.connectionState)")
    try expect(held.windows.first?.remainingPercentage == 30, "The numbers last read should stay on the surface")
    try expect(
        held.statusReason == .providerAnswerNotUnderstood,
        "The reason should say the answer changed, not that Codex stopped; got \(String(describing: held.statusReason))"
    )
    try expect(transport.terminations == 0, "An App Server that is answering must not be ended")
}

func aFirstCodexAnswerInAShapeNotKnownSaysWhy() async throws {
    let transport = FakeAppServerTransport { method, id in
        switch method {
        case "initialize":
            [FakeAppServerScript.initializeResult(id: id)]
        case "account/read":
            [FakeAppServerScript.authenticatedAccount(id: id)]
        case "account/rateLimits/read":
            [renamedRateLimits(id: id)]
        default:
            []
        }
    }
    let service = makeService(transport: transport)

    await service.connect()
    let snapshot = try await firstSnapshot(from: service)

    try expect(
        snapshot.connectionState == .disconnected(.providerAnswerNotUnderstood),
        "With nothing to keep, the Provider says the answer changed; got \(snapshot.connectionState)"
    )
    try expect(snapshot.windows.isEmpty, "A Provider never read must not show numbers")
}

private final class CodexTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = fixedNow
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Answers the first rate-limits read, then fails every one after it the way
/// the App Server does when it cannot reach its backend.
private func transportThatFailsAfterOneRead() -> FakeAppServerTransport {
    let reads = LockedCounter()
    return FakeAppServerTransport { method, id in
        switch method {
        case "initialize":
            [FakeAppServerScript.initializeResult(id: id)]
        case "account/read":
            [FakeAppServerScript.authenticatedAccount(id: id)]
        case "account/rateLimits/read":
            reads.next() == 1
                ? [FakeAppServerScript.rateLimits(id: id, primaryUsedPercent: 70, resetsAt: 1_700_003_600)]
                : [#"{"id":\#(id),"error":{"code":-32603,"message":"error sending request"}}"#]
        default:
            []
        }
    }
}

func staleCodexCapacityKeepsTheMomentItWasRead() async throws {
    let clock = CodexTestClock()
    let service = CodexCapacityService(
        clientInfo: CodexClientInfo(version: "0.1.0"),
        now: { clock.now },
        makeTransport: { transportThatFailsAfterOneRead() }
    )

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()
    _ = await iterator.next()

    clock.advance(10 * 60)
    await service.refresh()

    guard let held = await iterator.next() else {
        throw TestFailure(description: "A failed refresh should still publish a Capacity Snapshot")
    }
    try expect(held.connectionState == .stale, "A backend failure keeps the last reading as Stale Capacity")
    try expect(
        held.capturedAt == fixedNow,
        "Stale Capacity was read when it was read, not when it went stale; the surface says \"Last read at\" from this. Got \(held.capturedAt.timeIntervalSince(fixedNow))s later"
    )
}

func aCodexThatAnswersWithAnErrorSaysSoOverItsStaleCapacity() async throws {
    let service = makeService(transport: transportThatFailsAfterOneRead())

    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()
    _ = await iterator.next()
    await service.refresh()

    guard let held = await iterator.next() else {
        throw TestFailure(description: "A failed refresh should still publish a Capacity Snapshot")
    }
    try expect(
        held.statusReason == .providerCouldNotRead(detail: "error sending request"),
        "Stale Capacity should say why, in Codex's own words; got \(String(describing: held.statusReason))"
    )
}

private func accountTransport(_ answer: @escaping @Sendable (Int) -> String) -> FakeAppServerTransport {
    FakeAppServerTransport { method, id in
        switch method {
        case "initialize":
            [FakeAppServerScript.initializeResult(id: id)]
        case "account/read":
            [answer(id)]
        default:
            []
        }
    }
}

func anAccountAnswerOutsideTheSchemaIsNotReadAsSignedOut() async throws {
    // `requiresOpenaiAuth` is the one field the App Server's own schema
    // requires; an answer without it is not one this build understands.
    let service = makeService(transport: accountTransport { id in
        #"{"id":\#(id),"result":{"user":{"type":"chatgpt"}}}"#
    })

    await service.connect()
    let snapshot = try await firstSnapshot(from: service)

    try expect(
        snapshot.connectionState == .disconnected(.providerAnswerNotUnderstood),
        "An answer that breaks the schema should say so, not ask a signed-in person to sign in; got \(snapshot.connectionState)"
    )
}

func anAccountAnswerWithNoAccountIsSignedOutAsTheSchemaAllows() async throws {
    // The schema does not require `account`: a signed-out App Server may
    // leave it out rather than send null.
    let service = makeService(transport: accountTransport { id in
        #"{"id":\#(id),"result":{"requiresOpenaiAuth":true}}"#
    })

    await service.connect()
    let snapshot = try await firstSnapshot(from: service)

    try expect(
        snapshot.connectionState == .disconnected(.providerNotAuthenticated),
        "No account is signed out, got \(snapshot.connectionState)"
    )
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

func askingForTheStateAlreadyHeldAnnouncesNothing() throws {
    let store = CapacityNotchStore(snapshots: MockCapacityCatalog.snapshots(capturedAt: fixedNow))

    var announced: [CapacityNotchStore.Presentation] = []
    let observer = store.$presentation.sink { announced.append($0) }
    defer { observer.cancel() }

    store.expand()
    store.expand()
    store.expand()
    store.collapse()
    store.collapse()

    // A watcher that resizes the window on every announcement would restart
    // the motion on each repeat, so a repeat must not be announced.
    try expect(
        announced == [.compact, .expanded, .compact],
        "Only real changes should be announced, got \(announced)"
    )
}
