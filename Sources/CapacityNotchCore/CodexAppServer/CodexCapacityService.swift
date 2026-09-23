import Foundation

/// Connects Codex and turns its App Server readings into Capacity Snapshots.
///
/// The service owns exactly one App Server process at a time: it starts the
/// process on connect, ends that same process on disconnect or quit, and never
/// touches a Codex process it did not start.
public actor CodexCapacityService {
    public typealias TransportFactory = @Sendable () throws -> CodexAppServerTransport?

    private let clientInfo: CodexClientInfo
    private let now: @Sendable () -> Date
    private let makeTransport: TransportFactory

    private var client: CodexAppServerClient?
    private var notificationLoop: Task<Void, Never>?
    private var lastRateLimits: CodexRateLimitSnapshot?
    /// When `lastRateLimits` was read, which is what Stale Capacity reports as
    /// its reading time — not the moment a later read failed.
    private var lastReadAt: Date?

    public nonisolated let snapshots: AsyncStream<CapacitySnapshot>
    private nonisolated let snapshotContinuation: AsyncStream<CapacitySnapshot>.Continuation

    public init(
        clientInfo: CodexClientInfo,
        now: @escaping @Sendable () -> Date = { Date() },
        makeTransport: @escaping TransportFactory = {
            CodexInstallation.locate().map { CodexProcessTransport(executablePath: $0) }
        }
    ) {
        self.clientInfo = clientInfo
        self.now = now
        self.makeTransport = makeTransport

        var capturedContinuation: AsyncStream<CapacitySnapshot>.Continuation!
        snapshots = AsyncStream { capturedContinuation = $0 }
        snapshotContinuation = capturedContinuation
    }

    public var isConnected: Bool { client != nil }

    /// Starts one App Server and publishes the Capacity it reports. Calling
    /// this while already connected does not start a second process.
    public func connect() async {
        guard client == nil else { return }

        let transport: CodexAppServerTransport?
        do {
            transport = try makeTransport()
        } catch {
            emitDisconnected(.providerIncompatible(detail: "\(error)"))
            return
        }

        guard let transport else {
            emitDisconnected(.providerNotInstalled)
            return
        }

        let client = CodexAppServerClient(transport: transport)
        do {
            try await client.start()
        } catch {
            emitDisconnected(.providerIncompatible(detail: "the App Server did not start."))
            return
        }
        self.client = client

        do {
            _ = try await client.send(
                method: CodexAppServerMethod.initialize,
                params: clientInfo.initializeParams
            )
            try await client.notify(method: CodexAppServerMethod.initialized)
        } catch {
            await tearDown()
            emitDisconnected(.providerIncompatible(detail: handshakeDetail(for: error)))
            return
        }

        do {
            let account = try await client.send(
                method: CodexAppServerMethod.readAccount,
                // The App Server rejects `account/read` without a params
                // object, so an empty one is sent rather than none.
                params: [:],
                as: CodexAccountResponse.self
            )
            guard account.isAuthenticated else {
                await tearDown()
                emitDisconnected(.providerNotAuthenticated)
                return
            }
        } catch is DecodingError {
            await tearDown()
            emitDisconnected(.providerAnswerNotUnderstood)
            return
        } catch {
            await tearDown()
            emitDisconnected(.providerUnavailable(detail: detail(for: error)))
            return
        }

        observeNotifications(from: client)
        await refresh()
    }

    /// Re-reads Capacity from the App Server already running.
    public func refresh() async {
        guard let client else { return }

        do {
            let response = try await client.send(
                method: CodexAppServerMethod.readRateLimits,
                as: CodexRateLimitsResponse.self
            )
            let readAt = now()
            lastRateLimits = response.rateLimits
            lastReadAt = readAt
            snapshotContinuation.yield(
                CodexCapacityMapper.snapshot(from: response.rateLimits, capturedAt: readAt)
            )
        } catch let failure as JSONRPCFailure {
            // The App Server answered, so it is alive; it just could not reach
            // the backend. The last reading becomes Stale Capacity and the
            // next refresh tries again, rather than the Provider vanishing
            // over one failed read.
            await holdLastCapacityAsStale(because: .providerCouldNotRead(detail: failure.message))
        } catch is DecodingError {
            // Also alive: it answered, in a shape this build cannot read —
            // what a newer Codex looks like. Restarting it would get the same
            // answer, so the last reading stays and the reason says so.
            await holdLastCapacityAsStale(because: .providerAnswerNotUnderstood)
        } catch {
            await tearDown()
            emitDisconnected(.providerUnavailable(detail: detail(for: error)))
        }
    }

    /// Keeps the last observed Capacity on the surface, marked Stale and saying
    /// why. With nothing observed yet there is nothing to keep, so the
    /// Provider goes disconnected for the same reason instead.
    private func holdLastCapacityAsStale(because reason: CapacityStatusReason) async {
        guard let lastRateLimits else {
            await tearDown()
            emitDisconnected(reason)
            return
        }

        snapshotContinuation.yield(
            CodexCapacityMapper.snapshot(
                from: lastRateLimits,
                capturedAt: lastReadAt ?? now(),
                connectionState: .stale,
                statusReason: reason
            )
        )
    }

    /// Ends the App Server this service started, and nothing else.
    public func disconnect() async {
        await tearDown()
    }

    private func observeNotifications(from client: CodexAppServerClient) {
        let stream = client.notifications
        notificationLoop = Task { [weak self] in
            for await notification in stream {
                await self?.apply(notification)
            }
            await self?.handleAppServerExit()
        }
    }

    private func apply(_ notification: CodexNotification) {
        guard notification.method == CodexAppServerMethod.rateLimitsUpdated else { return }
        guard let update = try? JSONDecoder().decode(
            CodexRateLimitsUpdatedNotification.self,
            from: notification.params
        ) else { return }

        let merged = lastRateLimits.map {
            CodexCapacityMapper.merge(update.rateLimits, into: $0)
        } ?? update.rateLimits

        let readAt = now()
        lastRateLimits = merged
        lastReadAt = readAt
        snapshotContinuation.yield(CodexCapacityMapper.snapshot(from: merged, capturedAt: readAt))
    }

    private func handleAppServerExit() async {
        guard client != nil else { return }
        await tearDown()
        emitDisconnected(.providerUnavailable(detail: "the App Server stopped."))
    }

    private func tearDown() async {
        notificationLoop?.cancel()
        notificationLoop = nil
        lastRateLimits = nil
        lastReadAt = nil

        // The connection is given up before the App Server is asked to stop,
        // not after. Stopping is an await, and the notification loop ending
        // arrives at this same method while that await is suspended — which
        // ended the process twice, and would end a second connection's
        // process if one had been made in between.
        guard let client else { return }
        self.client = nil
        await client.stop()
    }

    private func emitDisconnected(_ reason: CapacityStatusReason) {
        snapshotContinuation.yield(
            CapacitySnapshot.disconnected(provider: .codex, capturedAt: now(), reason: reason)
        )
    }

    private func handshakeDetail(for error: Error) -> String {
        if let failure = error as? JSONRPCFailure {
            return "the App Server rejected `initialize` (\(failure.message))."
        }
        return "this Codex build does not speak the App Server protocol."
    }

    private func detail(for error: Error) -> String {
        if let failure = error as? JSONRPCFailure {
            return failure.message
        }
        return "the connection closed."
    }
}
