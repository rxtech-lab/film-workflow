import Testing
@testable import JSONRenderUI

@Suite("json-render spec decoding")
struct JSONRenderSpecTests {
    @Test("Decodes a well-formed spec")
    func decodesSpec() throws {
        let spec = try JSONRenderSpec.decode(json: """
        {
          "root": "page",
          "elements": {
            "page": { "type": "Stack", "props": { "spacing": 16 }, "children": ["hero"] },
            "hero": { "type": "Heading", "props": { "text": "Pick a look" } }
          }
        }
        """)
        #expect(spec.root == "page")
        #expect(spec.elements.count == 2)
        #expect(spec.element?.type == "Stack")
        #expect(spec.element("hero")?.props["text"]?.string == "Pick a look")
        #expect(spec.element?.children == ["hero"])
    }

    @Test("A missing root is the one thing that fails")
    func missingRootThrows() {
        #expect(throws: JSONRenderSpecError.self) {
            try JSONRenderSpec.decode(json: """
            { "root": "nope", "elements": { "page": { "type": "Stack" } } }
            """)
        }
        #expect(throws: (any Error).self) {
            try JSONRenderSpec.decode(json: #"{ "elements": {} }"#)
        }
    }

    @Test("An element with no type still decodes, as Unknown")
    func unknownTypeSurvives() throws {
        let spec = try JSONRenderSpec.decode(json: """
        {
          "root": "page",
          "elements": {
            "page": { "props": {}, "children": ["a", "b"] },
            "a": { "type": "", "props": {} },
            "b": { "type": "Sparkline", "props": {} }
          }
        }
        """)
        #expect(spec.element?.type == JSONRenderSpec.unknownType)
        #expect(spec.element("a")?.type == JSONRenderSpec.unknownType)
        #expect(spec.element("b")?.type == "Sparkline")
        #expect(spec.unsupportedTypes(in: ["Stack"]).contains("Sparkline"))
    }

    @Test("Malformed children are salvaged rather than fatal")
    func lenientChildren() throws {
        let spec = try JSONRenderSpec.decode(json: """
        {
          "root": "page",
          "elements": {
            "page": { "type": "Stack", "children": ["a", { "type": "Text" }, "missing"] },
            "a": { "type": "Text", "props": { "text": "hi" } }
          }
        }
        """)
        #expect(spec.element?.children == ["a", "missing"])
        #expect(spec.danglingChildren == ["missing"])
    }

    @Test("A single child id may be written unwrapped")
    func singleChild() throws {
        let spec = try JSONRenderSpec.decode(json: """
        {
          "root": "page",
          "elements": {
            "page": { "type": "Card", "children": "a" },
            "a": { "type": "Text" }
          }
        }
        """)
        #expect(spec.element?.children == ["a"])
    }
}
