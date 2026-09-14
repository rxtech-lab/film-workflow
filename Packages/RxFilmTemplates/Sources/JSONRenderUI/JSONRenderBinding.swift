import Foundation
import SwiftUI

/// Resolves a prop that may be a literal or a reference into state.
///
/// json-render props come in three shapes: a plain value, `{"$state": path}`
/// for a one-way read, and `{"$bindState": path}` for a two-way binding on an
/// input. `$template` interpolates state into a string. Anything else is
/// treated as a literal, so an unfamiliar directive shows up as visible text
/// rather than an empty card.
public struct JSONRenderResolver {
    public let state: JSONRenderState

    public init(state: JSONRenderState) {
        self.state = state
    }

    // MARK: - Values

    public func resolve(_ value: JSONRenderValue?) -> JSONRenderValue {
        guard let value else { return .null }
        if let path = Self.statePath(value) {
            return state.value(at: path) ?? .null
        }
        if let template = value["$template"]?.string {
            return .string(interpolate(template))
        }
        if let condition = value["$cond"] {
            let holds = evaluate(JSONRenderCondition(value: condition))
            let branch = holds ? value["$then"] : value["$else"]
            return resolve(branch)
        }
        if let array = value.array {
            return .array(array.map { resolve($0) })
        }
        return value
    }

    public func string(_ value: JSONRenderValue?) -> String? {
        let resolved = resolve(value)
        return resolved.isNull ? nil : resolved.string
    }

    public func number(_ value: JSONRenderValue?) -> Double? { resolve(value).number }

    public func integer(_ value: JSONRenderValue?) -> Int? { resolve(value).integer }

    public func bool(_ value: JSONRenderValue?) -> Bool? { resolve(value).bool }

    /// A layout number. Separate from ``number(_:)`` so call sites do not have
    /// to disambiguate `CGFloat.init` at every use.
    public func cgFloat(_ value: JSONRenderValue?) -> CGFloat? {
        resolve(value).number.map { CGFloat($0) }
    }

    public func array(_ value: JSONRenderValue?) -> [JSONRenderValue] {
        resolve(value).array ?? []
    }

    /// The path an input writes to, from either directive: a spec that says
    /// `$state` on a control still means "this control owns that value".
    public static func bindPath(_ value: JSONRenderValue?) -> String? {
        guard let value else { return nil }
        return value["$bindState"]?.string ?? value["$state"]?.string
    }

    static func statePath(_ value: JSONRenderValue) -> String? {
        value["$state"]?.string ?? value["$bindState"]?.string
    }

    public func binding(
        for prop: JSONRenderValue?,
        default fallback: JSONRenderValue = .null
    ) -> Binding<JSONRenderValue>? {
        guard let path = Self.bindPath(prop) else { return nil }
        return state.binding(for: path, default: fallback)
    }

    // MARK: - Templates

    private func interpolate(_ template: String) -> String {
        // `${/path/to/value}` is the only placeholder json-render defines.
        var output = ""
        var remainder = Substring(template)
        while let start = remainder.range(of: "${") {
            output += remainder[remainder.startIndex..<start.lowerBound]
            let afterOpen = remainder[start.upperBound...]
            guard let end = afterOpen.range(of: "}") else {
                output += remainder[start.lowerBound...]
                return output
            }
            let path = String(afterOpen[afterOpen.startIndex..<end.lowerBound])
            output += state.value(at: path)?.string ?? ""
            remainder = afterOpen[end.upperBound...]
        }
        output += remainder
        return output
    }

    // MARK: - Conditions

    public func evaluate(_ conditions: [JSONRenderCondition]) -> Bool {
        conditions.allSatisfy { evaluate($0) }
    }

    public func evaluate(_ condition: JSONRenderCondition) -> Bool {
        evaluate(value: condition.value)
    }

    private func evaluate(value: JSONRenderValue) -> Bool {
        if let object = value.object {
            if let negated = object["not"] ?? object["$not"] {
                return !evaluate(value: negated)
            }
            if let operands = (object["eq"] ?? object["$eq"])?.array, operands.count == 2 {
                return resolve(operands[0]) == resolve(operands[1])
            }
            if let operands = (object["ne"] ?? object["$ne"])?.array, operands.count == 2 {
                return resolve(operands[0]) != resolve(operands[1])
            }
            if let operands = (object["and"] ?? object["$and"])?.array {
                return operands.allSatisfy { evaluate(value: $0) }
            }
            if let operands = (object["or"] ?? object["$or"])?.array {
                return operands.contains { evaluate(value: $0) }
            }
            if object["$state"] != nil || object["$bindState"] != nil {
                return resolve(value).isTruthy
            }
        }
        return resolve(value).isTruthy
    }
}
