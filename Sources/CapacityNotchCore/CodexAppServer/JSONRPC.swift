import Foundation

/// One inbound JSON-RPC line from an App Server.
public enum JSONRPCInbound: Equatable, Sendable {
    case response(id: Int, result: Data)
    case failure(id: Int, error: JSONRPCFailure)
    case notification(method: String, params: Data)

    /// Parses one newline-delimited JSON-RPC message.
    ///
    /// Returns `nil` for blank lines and for messages this client has no use
    /// for, such as server-to-client requests it never opted into.
    public static func parse(line: String) throws -> JSONRPCInbound? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JSONRPCTransportError.malformedMessage(trimmed)
        }

        let identifier = object["id"] as? Int

        if let method = object["method"] as? String {
            guard identifier == nil else { return nil }
            let params = object["params"] ?? [String: Any]()
            return .notification(method: method, params: try encode(params))
        }

        guard let identifier else { throw JSONRPCTransportError.malformedMessage(trimmed) }

        if let error = object["error"] as? [String: Any] {
            return .failure(
                id: identifier,
                error: JSONRPCFailure(
                    code: error["code"] as? Int ?? 0,
                    message: error["message"] as? String ?? "Unknown App Server error"
                )
            )
        }

        let result = object["result"] ?? [String: Any]()
        return .response(id: identifier, result: try encode(result))
    }

    private static func encode(_ value: Any) throws -> Data {
        if JSONSerialization.isValidJSONObject(value) {
            return try JSONSerialization.data(withJSONObject: value)
        }
        return Data("null".utf8)
    }
}

public struct JSONRPCFailure: Error, Equatable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public enum JSONRPCTransportError: Error, Equatable, Sendable {
    case malformedMessage(String)
    case connectionClosed
}

/// Builds one outbound JSON-RPC line.
public enum JSONRPCOutbound {
    public static func request(
        id: Int,
        method: String,
        params: [String: Any]? = nil
    ) throws -> String {
        var object: [String: Any] = ["method": method, "id": id]
        if let params { object["params"] = params }
        return try line(object)
    }

    public static func notification(
        method: String,
        params: [String: Any]? = nil
    ) throws -> String {
        var object: [String: Any] = ["method": method]
        if let params { object["params"] = params }
        return try line(object)
    }

    private static func line(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw JSONRPCTransportError.malformedMessage("\(object)")
        }
        return text
    }
}
