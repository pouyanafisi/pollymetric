import CryptoKit
import Foundation

struct MCPClientRecord: Identifiable, Sendable {
    var id: String
    var name: String
    var scope: String
    var created: Date
    var lastUsed: Date?
    var callCount: Int
    var revoked: Bool
}

struct MCPCallRecord: Identifiable, Sendable {
    var id: Int64
    var clientID: String
    var date: Date
    var tool: String
    var allowed: Bool
}

enum MCPToken {
    static func generate() -> String {
        var random = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }).base64EncodedString()
    }
    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct MCPFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum MCPJSON {
    static func encode(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }
    static func error(id: Any, code: Int = -32000, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}
