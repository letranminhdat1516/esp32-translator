import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
}

public struct HookEvent: Sendable {
    public let name: String
    public let sessionId: String
    public let cwd: String
    public let toolName: String?
    public let toolInput: [String: JSONValue]
    public let notificationType: String?
    public let lastAssistantMessage: String?
    public let transcriptPath: String?

    private struct Raw: Decodable {
        let hook_event_name: String
        let session_id: String?
        let cwd: String?
        let tool_name: String?
        let tool_input: [String: JSONValue]?
        let notification_type: String?
        let last_assistant_message: String?
        let transcript_path: String?
    }

    public static func parse(_ data: Data) throws -> HookEvent {
        let r = try JSONDecoder().decode(Raw.self, from: data)
        return HookEvent(name: r.hook_event_name, sessionId: r.session_id ?? "", cwd: r.cwd ?? "",
                         toolName: r.tool_name, toolInput: r.tool_input ?? [:],
                         notificationType: r.notification_type,
                         lastAssistantMessage: r.last_assistant_message, transcriptPath: r.transcript_path)
    }
}
