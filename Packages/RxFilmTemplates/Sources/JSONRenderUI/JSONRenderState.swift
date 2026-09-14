import Foundation
import Observation
import SwiftUI

/// The values a rendered spec reads and writes.
///
/// Paths are slash-separated (`/footage/hero`, matching the JSON-pointer style
/// json-render uses), and intermediate objects are created on write so a spec
/// can bind straight to a nested path without declaring it first.
@Observable
public final class JSONRenderState {
    public private(set) var root: JSONRenderValue

    public init(_ root: JSONRenderValue = .object([:])) {
        self.root = .object(root.object ?? [:])
    }

    public convenience init(any value: Any?) {
        self.init(JSONRenderValue.from(any: value))
    }

    public convenience init(json: String) {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONRenderValue.self, from: data)
        else {
            self.init()
            return
        }
        self.init(value)
    }

    // MARK: - Reading and writing

    public func value(at path: String) -> JSONRenderValue? {
        Self.value(at: Self.components(path), in: root)
    }

    public func set(_ value: JSONRenderValue, at path: String) {
        let components = Self.components(path)
        guard !components.isEmpty else { return }
        root = Self.setting(value, at: components, in: root)
    }

    public func binding(
        for path: String,
        default fallback: JSONRenderValue = .null
    ) -> Binding<JSONRenderValue> {
        Binding(
            get: { [weak self] in self?.value(at: path) ?? fallback },
            set: { [weak self] newValue in self?.set(newValue, at: path) }
        )
    }

    /// Everything the user picked, as plain JSON for sending back to the agent.
    public var snapshot: JSONRenderValue { root }

    public var snapshotJSON: String { root.jsonString ?? "{}" }

    public var dictionary: [String: Any] {
        (root.anyValue as? [String: Any]) ?? [:]
    }

    // MARK: - Paths

    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func value(
        at components: [String],
        in value: JSONRenderValue
    ) -> JSONRenderValue? {
        guard let head = components.first else { return value }
        let rest = Array(components.dropFirst())
        if let object = value.object, let child = object[head] {
            return self.value(at: rest, in: child)
        }
        // A numeric component indexes an array, so a spec can bind to one item
        // of a list it also rendered.
        if let array = value.array, let index = Int(head), array.indices.contains(index) {
            return self.value(at: rest, in: array[index])
        }
        return nil
    }

    private static func setting(
        _ newValue: JSONRenderValue,
        at components: [String],
        in value: JSONRenderValue
    ) -> JSONRenderValue {
        guard let head = components.first else { return newValue }
        let rest = Array(components.dropFirst())

        if let index = Int(head), var array = value.array, index >= 0 {
            // Grow rather than drop the write: a spec that binds `/picks/2`
            // against a two-item initial state would otherwise render a control
            // that silently does nothing when clicked.
            guard index < 1000 else { return value }
            while array.count <= index { array.append(.null) }
            array[index] = setting(newValue, at: rest, in: array[index])
            return .array(array)
        }

        var object = value.object ?? [:]
        object[head] = setting(newValue, at: rest, in: object[head] ?? .object([:]))
        return .object(object)
    }
}
