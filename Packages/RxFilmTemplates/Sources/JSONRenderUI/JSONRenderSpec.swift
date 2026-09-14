import Foundation

/// A json-render document: one root element id and a flat map of elements.
///
/// Decoding is deliberately forgiving. The spec is written by a language model,
/// and a single unfamiliar element should cost the user that one card, not the
/// whole page — so an element with a missing or unknown type becomes
/// ``JSONRenderElement/unknownType`` and renders as a small placeholder.
/// Only a missing `root` or `elements` throws, because neither leaves anything
/// to draw.
public nonisolated struct JSONRenderSpec: Sendable, Hashable, Codable {
    public static let unknownType = "Unknown"

    public var root: String
    public var elements: [String: JSONRenderElement]

    public init(root: String, elements: [String: JSONRenderElement]) {
        self.root = root
        self.elements = elements
    }

    private enum CodingKeys: String, CodingKey {
        case root
        case elements
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(String.self, forKey: .root)
        elements = try container.decode([String: JSONRenderElement].self, forKey: .elements)
        guard elements[root] != nil else {
            throw JSONRenderSpecError.rootNotFound(root)
        }
    }

    public static func decode(_ data: Data) throws -> JSONRenderSpec {
        try JSONDecoder().decode(JSONRenderSpec.self, from: data)
    }

    public static func decode(json: String) throws -> JSONRenderSpec {
        guard let data = json.data(using: .utf8) else {
            throw JSONRenderSpecError.notUTF8
        }
        return try decode(data)
    }

    /// Builds a spec from already-parsed JSON, for a tool handler that has the
    /// arguments as a dictionary.
    public static func decode(any value: Any) throws -> JSONRenderSpec {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try decode(data)
    }

    public var element: JSONRenderElement? { elements[root] }

    public func element(_ id: String) -> JSONRenderElement? { elements[id] }

    /// Child ids that name no element. Reported back to the agent so it can fix
    /// the spec instead of silently losing a section.
    public var danglingChildren: [String] {
        var missing: Set<String> = []
        for element in elements.values {
            for child in element.children where elements[child] == nil {
                missing.insert(child)
            }
        }
        return missing.sorted()
    }

    /// Element types outside the catalog. Same purpose as ``danglingChildren``.
    public func unsupportedTypes(in catalog: Set<String>) -> [String] {
        var unsupported: Set<String> = []
        for element in elements.values where !catalog.contains(element.type) {
            unsupported.insert(element.type)
        }
        return unsupported.sorted()
    }
}

public nonisolated enum JSONRenderSpecError: LocalizedError, Equatable {
    case notUTF8
    case rootNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notUTF8:
            "The spec is not valid UTF-8 text."
        case .rootNotFound(let id):
            "The spec's root \"\(id)\" is not present in `elements`."
        }
    }
}

/// One node of a spec.
public nonisolated struct JSONRenderElement: Sendable, Hashable, Codable {
    public var type: String
    public var props: [String: JSONRenderValue]
    public var children: [String]
    /// Conditions that all have to hold for the element to render.
    public var visible: [JSONRenderCondition]

    public init(
        type: String,
        props: [String: JSONRenderValue] = [:],
        children: [String] = [],
        visible: [JSONRenderCondition] = []
    ) {
        self.type = type
        self.props = props
        self.children = children
        self.visible = visible
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case props
        case children
        case visible
    }

    public init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = JSONRenderElement(type: JSONRenderSpec.unknownType)
            return
        }
        let type = (try? container.decode(String.self, forKey: .type)) ?? JSONRenderSpec.unknownType
        self.type = type.isEmpty ? JSONRenderSpec.unknownType : type
        props = (try? container.decode([String: JSONRenderValue].self, forKey: .props)) ?? [:]

        // Children may arrive as a list of ids, a single id, or a list with a
        // stray object in it; keep every id we can recognise.
        if let ids = try? container.decode([String].self, forKey: .children) {
            children = ids
        } else if let id = try? container.decode(String.self, forKey: .children) {
            children = [id]
        } else if let mixed = try? container.decode([JSONRenderValue].self, forKey: .children) {
            children = mixed.compactMap { if case .string(let id) = $0 { id } else { nil } }
        } else {
            children = []
        }

        if let conditions = try? container.decode([JSONRenderCondition].self, forKey: .visible) {
            visible = conditions
        } else if let single = try? container.decode(JSONRenderCondition.self, forKey: .visible) {
            visible = [single]
        } else {
            visible = []
        }
    }

    public func prop(_ name: String) -> JSONRenderValue? { props[name] }
}

/// A `visible` clause. Supports the handful of shapes a wizard page needs:
/// a state reference read for truthiness, equality, and negation.
public nonisolated struct JSONRenderCondition: Sendable, Hashable, Codable {
    public var value: JSONRenderValue

    public init(value: JSONRenderValue) { self.value = value }

    public init(from decoder: any Decoder) throws {
        value = try JSONRenderValue(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }
}
