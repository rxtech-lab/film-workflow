import Foundation

/// A JSON value inside a render spec.
///
/// The package carries its own JSON type rather than borrowing the agent SDK's:
/// a spec can arrive from anywhere (a tool call, a fixture, a file), and the
/// renderer should not drag a networking dependency behind it.
public nonisolated enum JSONRenderValue: Sendable, Hashable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONRenderValue])
    case object([String: JSONRenderValue])

    // MARK: - Accessors

    public var string: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): String(value)
        default: nil
        }
    }

    public var number: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        case .bool(let value): value ? 1 : 0
        default: nil
        }
    }

    public var integer: Int? { number.map { Int($0.rounded()) } }

    public var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): ["true", "yes", "1"].contains(value.lowercased())
        default: nil
        }
    }

    public var array: [JSONRenderValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONRenderValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Truthiness for `visible` conditions, following the JavaScript rules a
    /// spec author would expect: empty string, zero, null and empty collections
    /// are false.
    public var isTruthy: Bool {
        switch self {
        case .string(let value): !value.isEmpty
        case .number(let value): value != 0
        case .bool(let value): value
        case .null: false
        case .array(let value): !value.isEmpty
        case .object(let value): !value.isEmpty
        }
    }

    public subscript(key: String) -> JSONRenderValue? { object?[key] }

    // MARK: - Codable

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONRenderValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONRenderValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: - Foundation bridging

    /// Builds a value from `JSONSerialization` output, so a handler can hand
    /// over the arguments it already parsed.
    public static func from(any value: Any?) -> JSONRenderValue {
        switch value {
        case nil, is NSNull: return .null
        case let value as JSONRenderValue: return value
        case let value as String: return .string(value)
        case let value as NSNumber:
            // Ahead of the `Bool` case on purpose. `JSONSerialization` boxes
            // every number as `NSNumber`, and the bridge to `Bool` succeeds for
            // 0 and 1 — so matching `Bool` first would turn `"columns": 1` into
            // `true`. The shared true/false instances are the only real
            // booleans, and their type id is what identifies them.
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            return .number(value.doubleValue)
        case let value as Bool: return .bool(value)
        case let value as Double: return .number(value)
        case let value as Int: return .number(Double(value))
        case let value as [Any]: return .array(value.map { JSONRenderValue.from(any: $0) })
        case let value as [String: Any]:
            return .object(value.mapValues { JSONRenderValue.from(any: $0) })
        default: return .null
        }
    }

    public var anyValue: Any? {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .null: nil
        case .array(let value): value.map { $0.anyValue as Any }
        case .object(let value): value.compactMapValues { $0.anyValue }
        }
    }

    public var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
