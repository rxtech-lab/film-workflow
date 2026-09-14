import Foundation
import Testing
@testable import JSONRenderUI

@Suite("json-render state and bindings")
@MainActor
struct JSONRenderStateTests {
    @Test("Writes create the path they need")
    func nestedWrite() {
        let state = JSONRenderState()
        state.set(.string("imported:1"), at: "/footage/hero")
        #expect(state.value(at: "/footage/hero")?.string == "imported:1")
        #expect(state.value(at: "/footage")?.object?.count == 1)
        #expect(state.value(at: "/nothing/here") == nil)
    }

    @Test("Initial state comes back out as a snapshot")
    func snapshotRoundTrip() {
        let state = JSONRenderState(json: #"{"style":{"captions":true}}"#)
        #expect(state.value(at: "/style/captions")?.bool == true)
        state.set(.string("calm"), at: "/style/tone")
        let dictionary = state.dictionary
        let style = dictionary["style"] as? [String: Any]
        #expect(style?["tone"] as? String == "calm")
        #expect(state.snapshotJSON.contains("calm"))
    }

    @Test("A binding reads and writes the same path")
    func binding() {
        let state = JSONRenderState()
        let binding = state.binding(for: "/music/track", default: .string("none"))
        #expect(binding.wrappedValue.string == "none")
        binding.wrappedValue = .string("upbeat")
        #expect(state.value(at: "/music/track")?.string == "upbeat")
    }

    @Test("A JSON number stays a number, even when it is 0 or 1")
    func numbersAreNotBooleans() throws {
        // `JSONSerialization` boxes every number as `NSNumber`, and 0 and 1
        // bridge to `Bool` — so a spec's `"columns": 1` must not become `true`.
        let parsed = try JSONSerialization.jsonObject(
            with: Data(#"{"columns": 1, "spacing": 0, "captions": true}"#.utf8)
        )
        let value = JSONRenderValue.from(any: parsed)
        #expect(value["columns"] == .number(1))
        #expect(value["spacing"] == .number(0))
        #expect(value["captions"] == .bool(true))
        #expect(value["columns"]?.integer == 1)
    }

    @Test("Binding past the end of an array grows it instead of dropping the write")
    func writesPastTheEndOfAnArray() {
        // A spec may bind `/picks/2` against a two-item initial state; dropping
        // the write would render a control that does nothing when clicked.
        let state = JSONRenderState(json: #"{"picks":["a","b"]}"#)
        state.set(.string("c"), at: "/picks/2")
        #expect(state.value(at: "/picks/2")?.string == "c")
        #expect(state.value(at: "/picks")?.array?.count == 3)

        // A wild index is still refused rather than allocating.
        state.set(.string("x"), at: "/picks/99999")
        #expect(state.value(at: "/picks")?.array?.count == 3)
    }

    @Test("Props resolve through $state, $bindState and $template")
    func resolvesDirectives() {
        let state = JSONRenderState(json: #"{"user":{"name":"Ada"},"count":3}"#)
        let resolver = JSONRenderResolver(state: state)
        #expect(resolver.string(.object(["$state": .string("/user/name")])) == "Ada")
        #expect(resolver.integer(.object(["$state": .string("/count")])) == 3)
        #expect(resolver.string(.object(["$template": .string("Hi ${/user/name}!")])) == "Hi Ada!")
        #expect(resolver.string(.string("literal")) == "literal")
        #expect(JSONRenderResolver.bindPath(.object(["$bindState": .string("/a/b")])) == "/a/b")
    }

    @Test("Visibility conditions gate an element")
    func conditions() {
        let state = JSONRenderState(json: #"{"style":{"music":true,"tone":"calm"}}"#)
        let resolver = JSONRenderResolver(state: state)

        #expect(resolver.evaluate(JSONRenderCondition(value: .object(["$state": .string("/style/music")]))))
        #expect(!resolver.evaluate(JSONRenderCondition(value: .object(["$state": .string("/style/missing")]))))

        let negated = JSONRenderCondition(value: .object([
            "not": .object(["$state": .string("/style/music")]),
        ]))
        #expect(!resolver.evaluate(negated))

        let equals = JSONRenderCondition(value: .object([
            "eq": .array([.object(["$state": .string("/style/tone")]), .string("calm")]),
        ]))
        #expect(resolver.evaluate(equals))
    }
}
