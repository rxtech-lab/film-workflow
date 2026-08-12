import Foundation
import Testing

@testable import film_workflow

/// The `{{term}}` syntax: how a key matches, what a placeholder renders as, and
/// what happens to text a model got wrong.
///
/// Pure value logic, so no model container and no main-actor hop.
@Suite("Caption term placeholders")
struct CaptionTermPlaceholderTests {

    private let rxlab = CaptionTerm(
        text: "RxLab",
        note: "company name",
        variants: ["rex lab"],
        translations: ["zh-Hans": "睿析实验室", "ja": "RxLab研究所"]
    )

    /// A term with no wording anywhere, to exercise the fallback.
    private let remotion = CaptionTerm(text: "Remotion")

    private var resolver: CaptionTermResolver {
        CaptionTermResolver(terms: [rxlab, remotion])
    }

    // MARK: - Keys

    /// The reason the key joins tokens with no separator: a space-join would
    /// split "rx lab" into a different key than "RxLab", and would wedge spaces
    /// into every CJK key.
    @Test("Case, width, spacing and punctuation all fold into the same key")
    func keyFolding() {
        let expected = CaptionTermPlaceholder.key("RxLab")
        #expect(!expected.isEmpty)
        for spelling in ["RxLab", "rxlab", "RXLAB", "rx lab", "Rx-Lab", " rx  lab ", "ＲｘＬａｂ"] {
            #expect(CaptionTermPlaceholder.key(spelling) == expected, "\(spelling)")
        }
    }

    @Test("A CJK term keys without inserted spaces")
    func cjkKey() {
        #expect(CaptionTermPlaceholder.key("睿析") == CaptionTermPlaceholder.key("睿 析"))
        #expect(!CaptionTermPlaceholder.key("睿析").contains(" "))
    }

    @Test("Every spelling of a term reaches the term")
    func resolverMatchesEverySpelling() {
        let resolver = resolver
        for spelling in ["RxLab", "rxlab", "rx lab", "RX-LAB", "rex lab"] {
            #expect(resolver.term(forKey: spelling)?.text == "RxLab", "\(spelling)")
        }
    }

    // MARK: - Rendering

    @Test("A language with a wording renders that wording")
    func rendersWording() {
        #expect(
            resolver.render("我们在{{RxLab}}构建了它。", language: "zh-Hans")
                == "我们在睿析实验室构建了它。"
        )
    }

    @Test("A language with no wording falls back to the canonical spelling")
    func fallsBackToCanonicalText() {
        #expect(resolver.render("Built at {{RxLab}}.", language: "fr") == "Built at RxLab.")
        #expect(resolver.render("Built at {{Remotion}}.", language: "zh-Hans") == "Built at Remotion.")
        #expect(resolver.render("Built at {{RxLab}}.", language: "") == "Built at RxLab.")
    }

    @Test("A sloppily spelled placeholder still renders the approved wording")
    func rendersFromVariantSpelling() {
        #expect(resolver.render("{{ rx lab }}", language: "zh-Hans") == "睿析实验室")
        #expect(resolver.render("{{rex lab}}", language: "zh-Hans") == "睿析实验室")
    }

    @Test("An unknown key renders its own text, not braces")
    func unknownKeyRendersInnerText() {
        #expect(resolver.render("Ask {{Nobody}} first.", language: "zh-Hans") == "Ask Nobody first.")
        #expect(
            CaptionTermResolver.empty.render("Ask {{RxLab}}.", language: "zh-Hans")
                == "Ask RxLab."
        )
    }

    @Test("Several placeholders in one line, adjacent ones included")
    func multiplePlaceholders() {
        #expect(
            resolver.render("{{RxLab}}{{Remotion}} and {{RxLab}}", language: "ja")
                == "RxLab研究所Remotion and RxLab研究所"
        )
    }

    @Test("Text with no braces comes back identical")
    func fastPath() {
        let plain = "我们在睿析实验室构建了它。"
        #expect(resolver.render(plain, language: "zh-Hans") == plain)
    }

    /// The invariant everything downstream leans on: placeholder syntax never
    /// reaches a caption, an export or a subtitle file, however mangled the
    /// input. An unmatched `}}` is the one thing that survives — it was never a
    /// placeholder, and deleting text a user wrote would be worse.
    @Test("Placeholder syntax never survives rendering")
    func malformedNeverLeaks() {
        let inputs = [
            "{{", "}}", "{{}}", "{{a", "a}}", "{{{RxLab}}}", "{{a{{RxLab}}}}",
            "{{RxLab", "{{RxLab}", "}}{{RxLab}}{{", "{{ }}", "{{{{RxLab}}}}",
        ]
        for input in inputs {
            let rendered = resolver.render(input, language: "zh-Hans")
            #expect(!rendered.contains("{{"), "\(input) -> \(rendered)")
        }
    }

    @Test("Each malformed shape has a defined outcome")
    func malformedOutcomes() {
        let resolver = resolver
        #expect(resolver.render("}}", language: "zh-Hans") == "}}")
        #expect(resolver.render("a}}", language: "zh-Hans") == "a}}")
        #expect(resolver.render("{{a", language: "zh-Hans") == "a")
        #expect(resolver.render("{{RxLab}", language: "zh-Hans") == "RxLab}")
        #expect(resolver.render("{{}}", language: "zh-Hans") == "")
        #expect(resolver.render("{{{RxLab}}}", language: "zh-Hans") == "睿析实验室")
        #expect(resolver.render("{{{{RxLab}}}}", language: "zh-Hans") == "睿析实验室")
    }

    @Test("Nesting resolves the innermost placeholder")
    func nestedResolvesInner() {
        #expect(resolver.render("{{a{{RxLab}}}}", language: "zh-Hans") == "a睿析实验室")
    }

    // MARK: - Unresolved keys

    @Test("Only keys with no term are reported, once each")
    func unresolvedKeys() {
        let raw = "{{RxLab}} {{Nobody}} {{Nobody}} {{Remotion}}"
        #expect(resolver.unresolvedKeys(in: raw) == ["Nobody"])
        #expect(resolver.unresolvedKeys(in: "no braces here").isEmpty)
    }

    // MARK: - Sanitizing

    @Test("A matched key is rewritten to the term's canonical spelling")
    func canonicalizesOnWrite() {
        #expect(
            resolver.sanitize("在{{ rx lab }}", unwrapUnknown: true) == "在{{RxLab}}"
        )
        #expect(
            resolver.sanitize("在{{rex lab}}", unwrapUnknown: true) == "在{{RxLab}}"
        )
    }

    @Test("Single braces are promoted only when they name a term")
    func promotesKnownSingleBraces() {
        #expect(resolver.sanitize("{RxLab} costs {5}", unwrapUnknown: true) == "{{RxLab}} costs {5}")
        #expect(resolver.sanitize("{Nobody}", unwrapUnknown: true) == "{Nobody}")
    }

    /// The AI path unwraps a hallucinated placeholder — it renders as its inner
    /// text anyway. The hand-edit path keeps it, so writing the placeholder
    /// before adding the term doesn't silently lose the braces.
    @Test("Unknown keys unwrap for the model and survive for the user")
    func unknownKeyPolicy() {
        #expect(resolver.sanitize("Ask {{Nobody}}.", unwrapUnknown: true) == "Ask Nobody.")
        #expect(resolver.sanitize("Ask {{Nobody}}.", unwrapUnknown: false) == "Ask {{Nobody}}.")
    }

    @Test("Sanitizing sanitized text changes nothing")
    func idempotent() {
        let inputs = ["在{{ rx lab }}", "{RxLab}", "{{{RxLab}}}", "Ask {{Nobody}}.", "plain text", "}}x{{"]
        for input in inputs {
            for unwrap in [true, false] {
                let once = resolver.sanitize(input, unwrapUnknown: unwrap)
                let twice = resolver.sanitize(once, unwrapUnknown: unwrap)
                #expect(once == twice, "\(input) unwrap=\(unwrap): \(once) -> \(twice)")
            }
        }
    }

    // MARK: - Term storage

    @Test("Blank wordings never reach storage")
    func setTranslationDropsBlanks() {
        var term = CaptionTerm(text: "RxLab")
        term.setTranslation("  睿析实验室  ", language: "zh-Hans")
        #expect(term.translation("zh-Hans") == "睿析实验室")
        term.setTranslation("   ", language: "zh-Hans")
        #expect(term.translations["zh-Hans"] == nil)
        #expect(term.rendered(in: "zh-Hans") == "RxLab")
    }

    @Test("A term round-trips through Codable, and a legacy term decodes")
    func codable() throws {
        let data = try JSONEncoder().encode(rxlab)
        let decoded = try JSONDecoder().decode(CaptionTerm.self, from: data)
        #expect(decoded.translations == rxlab.translations)

        let legacy = Data(#"{"text":"RxLab","note":"","variants":[]}"#.utf8)
        let old = try JSONDecoder().decode(CaptionTerm.self, from: legacy)
        #expect(old.translations.isEmpty)
        #expect(old.rendered(in: "zh-Hans") == "RxLab")
    }

    // MARK: - Prompts

    @Test("The translation glossary asks for placeholders and names the wording")
    func translationPromptBlock() {
        let block = CaptionTermMatching.translationPromptBlock(
            [rxlab, remotion],
            target: "zh-Hans"
        )
        #expect(block.contains("{{RxLab}}"))
        #expect(block.contains("睿析实验室"))
        #expect(block.contains("{{Remotion}}"))
        // No wording set for Remotion, so the model is told what it becomes.
        #expect(block.contains("\"Remotion\""))
        // Variants stay out — they invite `{{rex lab}}`.
        #expect(!block.contains("rex lab"))
    }

    /// The splitter, the proofreader and the chat assistant all work on the
    /// original caption text, which must never grow braces.
    @Test("The plain glossary block stays placeholder-free")
    func plainPromptBlockHasNoBraces() {
        let block = CaptionTermMatching.promptBlock([rxlab, remotion])
        #expect(!block.contains("{{"))
        #expect(block.contains("RxLab"))
        #expect(block.contains("rex lab"))
    }
}
