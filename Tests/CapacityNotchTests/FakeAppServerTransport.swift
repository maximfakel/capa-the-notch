import CapacityNotchCore
import Foundation

/// An App Server that answers from a script instead of a Codex process.
final class FakeAppServerTransport: CodexAppServerTransport, @unchecked Sendable {
    typealias Responder = @Sendable (_ method: String, _ id: Int) -> [String]

    private let responder: Responder
    private let lock = NSLock()
    private var sentLines: [String] = []
    private var startCount = 0
    private var terminateCount = 0

    let incomingLines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init(responder: @escaping Responder) {
        self.responder = responder

        var captured: AsyncStream<String>.Continuation!
        incomingLines = AsyncStream { captured = $0 }
        continuation = captured
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sentLines
    }

    var starts: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCount
    }

    var terminations: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminateCount
    }

    func start() throws {
        lock.lock()
        startCount += 1
        lock.unlock()
    }

    func send(line: String) throws {
        lock.lock()
        sentLines.append(line)
        lock.unlock()

        guard
            let data = line.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String
        else { return }

        for reply in responder(method, object["id"] as? Int ?? 0) {
            continuation.yield(reply)
        }
    }

    /// Pushes a line the App Server sends on its own, such as a rolling update.
    func push(_ line: String) {
        continuation.yield(line)
    }

    func closeConnection() {
        continuation.finish()
    }

    func terminate() {
        lock.lock()
        terminateCount += 1
        lock.unlock()
        continuation.finish()
    }
}

/// Canned App Server replies for the handshake Capacity Notch performs.
enum FakeAppServerScript {
    static func initializeResult(id: Int) -> String {
        #"{"id":\#(id),"result":{"userAgent":{"name":"codex","version":"0.115.0"}}}"#
    }

    static func authenticatedAccount(id: Int) -> String {
        #"{"id":\#(id),"result":{"account":{"type":"chatgpt","email":"a@b.c","planType":"pro"},"requiresOpenaiAuth":true}}"#
    }

    static func signedOutAccount(id: Int) -> String {
        #"{"id":\#(id),"result":{"account":null,"requiresOpenaiAuth":true}}"#
    }

    static func rateLimits(id: Int, primaryUsedPercent: Int, resetsAt: Int) -> String {
        #"""
        {"id":\#(id),"result":{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":\#(primaryUsedPercent),"windowDurationMins":300,"resetsAt":\#(resetsAt)},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":\#(resetsAt + 1000)}}}}
        """#
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rateLimitsUpdated(primaryUsedPercent: Int, resetsAt: Int) -> String {
        #"""
        {"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":\#(primaryUsedPercent),"windowDurationMins":300,"resetsAt":\#(resetsAt)}}}}
        """#
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func methodNotFound(id: Int) -> String {
        #"{"id":\#(id),"error":{"code":-32601,"message":"Method not found"}}"#
    }
}
