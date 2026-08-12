import Foundation
import Testing

@testable import film_workflow

/// Checks the Whisper model catalog the Settings list is built from.
///
/// The download/select UI is only usable if this list populates, so it's worth
/// asserting rather than eyeballing.
@Suite("Whisper model store")
struct WhisperModelStoreTests {

    @Test("The model catalog populates with downloadable variants", .timeLimit(.minutes(1)))
    @MainActor
    func catalogPopulates() async throws {
        let store = WhisperModelStore.shared
        await store.refresh()

        // Offline is not a test failure — but then the offline fallback catalog
        // must still offer something, or Settings would show an empty list.
        if store.lastError != nil {
            #expect(!store.models.isEmpty, "offline fallback catalog must not be empty")
            return
        }

        #expect(!store.models.isEmpty)
        // Every entry needs the three things the row renders.
        for entry in store.models {
            #expect(!entry.variant.isEmpty)
            #expect(!entry.displayName.isEmpty)
            #expect(entry.approximateBytes > 0)
        }
        // A small model must be on offer — nobody should be forced to start with
        // a 1.6 GB download.
        #expect(store.models.contains { ["tiny", "base", "small"].contains($0.family) })
    }

    @Test("Display names are humanized from the raw variant id")
    func displayNames() {
        func name(_ variant: String) -> String {
            WhisperModelStore.ModelEntry(
                variant: variant,
                approximateBytes: 1,
                isRecommended: false,
                isInstalled: false,
                installedBytes: 0
            ).displayName
        }
        #expect(name("openai_whisper-base") == "Base")
        #expect(name("openai_whisper-large-v3") == "Large-v3")
        #expect(name("openai_whisper-small.en") == "Small.en")
    }

    @Test("English-only variants are flagged, multilingual ones are not")
    func multilingualDetection() {
        func entry(_ variant: String) -> WhisperModelStore.ModelEntry {
            .init(
                variant: variant, approximateBytes: 1, isRecommended: false,
                isInstalled: false, installedBytes: 0
            )
        }
        #expect(entry("openai_whisper-base").isMultilingual)
        #expect(!entry("openai_whisper-base.en").isMultilingual)
    }

    @Test("A size stated in the variant id beats the family estimate")
    func sizeParsedFromVariantID() {
        let mb: Int64 = 1024 * 1024
        // Real catalog entries: the suffix is authoritative.
        #expect(
            WhisperModelStore.approximateBytes(for: "distil-whisper_distil-large-v3_594MB")
            == 594 * mb
        )
        #expect(
            WhisperModelStore.approximateBytes(for: "openai_whisper-large-v3-v20240930_turbo_632MB")
            == 632 * mb
        )
        // No suffix falls back to the family estimate.
        #expect(WhisperModelStore.approximateBytes(for: "openai_whisper-tiny") == 75 * mb)
        #expect(WhisperModelStore.approximateBytes(for: "openai_whisper-large-v3") == 1600 * mb)
    }

    @Test("Family classification drives the size ordering")
    func familyClassification() {
        func family(_ variant: String) -> String {
            WhisperModelStore.ModelEntry(
                variant: variant, approximateBytes: 1, isRecommended: false,
                isInstalled: false, installedBytes: 0
            ).family
        }
        #expect(family("openai_whisper-tiny") == "tiny")
        #expect(family("openai_whisper-large-v3_turbo") == "large-v3")
        #expect(family("distil-whisper_distil-small.en") == "small")
    }

    @Test("A variant with no compiled model on disk does not count as installed")
    func installedDetectionIsStrict() {
        // Nothing is downloaded in a clean test environment, and a half-finished
        // download must not read as usable.
        #expect(!WhisperModelStore.isInstalled(variant: "openai_whisper-does-not-exist"))
    }
}
