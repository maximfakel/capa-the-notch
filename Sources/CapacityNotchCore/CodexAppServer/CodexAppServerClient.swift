import Foundation

public struct CodexNotification: Sendable {
    public let method: String
    public let params: Data
}

/// Request/response correlation over one App Server transport.
public actor CodexAppServerClient {
    private let transport: CodexAppServerTransport
    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var readLoop: Task<Void, Never>?
    private var sentMethods: [String] = []

    public nonisolated let notifications: AsyncStream<CodexNotification>
    private nonisolated let notificationContinuation: AsyncStream<CodexNotification>.Continuation

    public init(transport: CodexAppServerTransport) {
        self.transport = transport

        var capturedContinuation: AsyncStream<CodexNotification>.Continuation!
        notifications = AsyncStream { capturedContinuation = $0 }
        notificationContinuation = capturedContinuation
    }

    /// Every method this client has actually put on the wire, in order.
    public var methodsSent: [String] { sentMethods }

    public func start() throws {
        guard readLoop == nil else { return }
        try transport.start()

        let lines = transport.incomingLines
        readLoop = Task { [weak self] in
            for await line in lines {
                await self?.receive(line: line)
            }
            await self?.closeWithClosedConnection()
        }
    }

    public func stop() {
        readLoop?.cancel()
        readLoop = nil
        transport.terminate()
        closeWithClosedConnection()
    }

    /// Sends a request and decodes its result.
    public func send<Response: Decodable>(
        method: String,
        params: [String: Any]? = nil,
        as responseType: Response.Type
    ) async throws -> Response {
        let data = try await send(method: method, params: params)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    @discardableResult
    public func send(method: String, params: [String: Any]? = nil) async throws -> Data {
        try guardPermitted(method)

        nextRequestID += 1
        let id = nextRequestID
        let line = try JSONRPCOutbound.request(id: id, method: method, params: params)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                sentMethods.append(method)
                try transport.send(line: line)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    public func notify(method: String, params: [String: Any]? = nil) throws {
        try guardPermitted(method)
        sentMethods.append(method)
        try transport.send(line: try JSONRPCOutbound.notification(method: method, params: params))
    }

    private func guardPermitted(_ method: String) throws {
        guard CodexAppServerMethod.permittedOutbound.contains(method) else {
            throw CodexCapacityError.methodNotPermitted(method)
        }
    }

    private func receive(line: String) {
        guard let message = try? JSONRPCInbound.parse(line: line) else { return }

        switch message {
        case let .response(id, result):
            pending.removeValue(forKey: id)?.resume(returning: result)
        case let .failure(id, error):
            pending.removeValue(forKey: id)?.resume(throwing: error)
        case let .notification(method, params):
            notificationContinuation.yield(CodexNotification(method: method, params: params))
        }
    }

    private func closeWithClosedConnection() {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: JSONRPCTransportError.connectionClosed)
        }
        notificationContinuation.finish()
    }
}

public enum CodexCapacityError: Error, Equatable, Sendable {
    case methodNotPermitted(String)
}
