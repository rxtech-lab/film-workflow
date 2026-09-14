import Foundation
import Testing

@testable import film_workflow

/// Every request to our backend carries the language the app is drawn in, and
/// the backend answers marketplace text, taxonomy labels and refusals in it.
/// What matters here is the header's shape: the app's first language wins, the
/// rest follow as fallbacks the server may use when it has nothing better.
@Suite("Accept-Language")
struct BackendAcceptLanguageTests {
    @Test("Puts the app's own language first, the rest behind it")
    func ordersByPreference() {
        #expect(BackendConfig.acceptLanguage(for: ["zh-Hans"]) == "zh-Hans")
        #expect(BackendConfig.acceptLanguage(for: ["zh-Hans", "en"]) == "zh-Hans,en;q=0.9")
        #expect(BackendConfig.acceptLanguage(for: ["en", "zh-Hans"]) == "en,zh-Hans;q=0.9")
    }

    @Test("Never sends an empty header, and never sends Base as a language")
    func fallsBackToEnglish() {
        #expect(BackendConfig.acceptLanguage(for: []) == "en")
        #expect(BackendConfig.acceptLanguage(for: [""]) == "en")
        #expect(BackendConfig.acceptLanguage(for: ["Base", "zh-Hans"]) == "zh-Hans")
    }

    @Test("Stops at four languages, which is further than any server negotiates")
    func trimsLongLists() {
        let header = BackendConfig.acceptLanguage(for: ["zh-Hans", "en", "ja", "fr", "de"])
        #expect(header == "zh-Hans,en;q=0.9,ja;q=0.8,fr;q=0.7")
        #expect(!header.contains("de"))
    }
}
