import Foundation
import Testing

@testable import film_workflow

/// The path a refused model takes from the server's reply to the alert that
/// offers the picker.
///
/// The server answers `model_not_allowed` with neither the id it refused nor
/// the capability it refused it for, so every step here is about a fact being
/// added by the only layer that holds it — and about not losing it again.
@Suite("Unavailable model")
struct UnavailableModelTests {

    // MARK: - Naming

    @Test("The sending client fills in what the server left out")
    func namesModelAndCapability() {
        let named = BackendError.modelUnavailable(model: "", capability: nil)
            .namingModel("openai/gpt-image-1", capability: .image)

        let unavailable = try? #require(named.unavailableModel)
        #expect(unavailable?.model == "openai/gpt-image-1")
        #expect(unavailable?.capability == .image)
    }

    @Test("A client that already knew better is not overwritten")
    func keepsExistingNames() {
        // The image client retries on a refreshed id and reports *that* one;
        // an outer layer re-naming it would send the user after a model the
        // second attempt never used.
        let named = BackendError.modelUnavailable(model: "refreshed", capability: .image)
            .namingModel("stale", capability: .video)

        #expect(named.unavailableModel?.model == "refreshed")
        #expect(named.unavailableModel?.capability == .image)
    }

    @Test("Other rejections pass through untouched")
    func leavesOtherErrorsAlone() {
        // Call sites wrap their whole `catch` in this rather than switching
        // first, so anything that is not a model refusal has to survive it.
        let passed = BackendError.badRequest("nope").namingModel("m", capability: .chat)
        guard case .badRequest(let message) = passed else {
            Issue.record("badRequest was rewritten to \(passed)")
            return
        }
        #expect(message == "nope")
        #expect(passed.unavailableModel == nil)
    }

    @Test("A blank id is not quoted at the user")
    func describesAnUnnamedModel() {
        let description = BackendError.modelUnavailable(model: "", capability: nil)
            .errorDescription ?? ""
        #expect(!description.contains("“”"))
        #expect(description.contains("Settings"))
    }

    @Test("The description names the Settings row that chose the model")
    func describesTheSettingsRow() {
        let description = BackendError.modelUnavailable(model: "veo-3", capability: .video)
            .errorDescription ?? ""
        #expect(description.contains("veo-3"))
        #expect(description.contains(AICapability.video.settingsRowLabel))
    }

    // MARK: - Notice

    @Test("The notice is built only from a model refusal")
    func noticeIgnoresOtherErrors() {
        #expect(UnavailableModelNotice(BackendError.badRequest("nope")) == nil)
        #expect(UnavailableModelNotice(BackendError.unauthorized) == nil)
        #expect(UnavailableModelNotice(CocoaError(.fileNoSuchFile)) == nil)

        let notice = try? #require(
            UnavailableModelNotice(
                BackendError.modelUnavailable(model: "whisper-1", capability: .transcription)
            )
        )
        #expect(notice?.model == "whisper-1")
        #expect(notice?.capability == .transcription)
    }

    @Test("The alert message says which picker to open")
    func noticeMessageNamesThePicker() {
        let notice = UnavailableModelNotice(
            BackendError.modelUnavailable(model: "gpt-image-1", capability: .image)
        )
        let message = notice?.message ?? ""
        #expect(message.contains("gpt-image-1"))
        #expect(message.contains(AICapability.image.settingsRowLabel))
    }

    // MARK: - The Settings picker

    private static func model(_ id: String, capability: AICapability = .image) -> PickableModel {
        PickableModel(
            id: id,
            provider: "gateway",
            displayName: id,
            capability: capability.rawValue,
            estimate: nil
        )
    }

    @Test("A saved id the catalog no longer lists is flagged")
    func flagsAStaleSelection() {
        #expect(
            SubscriptionModelPicker.isUnavailable(
                "dropped-model",
                in: [Self.model("kept-model")],
                isCatalogLoaded: true
            )
        )
    }

    @Test("A listed id is not flagged")
    func acceptsAListedSelection() {
        #expect(
            !SubscriptionModelPicker.isUnavailable(
                "kept-model",
                in: [Self.model("kept-model")],
                isCatalogLoaded: true
            )
        )
    }

    @Test("Nothing is flagged against a catalog that did not load")
    func staysQuietWithoutACatalog() {
        // This is the case that would turn every offline launch into a false
        // alarm: no list loaded says nothing about the saved id.
        #expect(
            !SubscriptionModelPicker.isUnavailable(
                "some-model",
                in: [],
                isCatalogLoaded: false
            )
        )
        // A catalog that *did* load and offers nothing for this capability is
        // the opposite case, and is a real problem.
        #expect(
            SubscriptionModelPicker.isUnavailable(
                "some-model",
                in: [],
                isCatalogLoaded: true
            )
        )
    }

    @Test("An empty selection is the CLI's own default, not a stale id")
    func ignoresAnEmptySelection() {
        #expect(!SubscriptionModelPicker.isUnavailable("", in: [], isCatalogLoaded: true))
        #expect(!SubscriptionModelPicker.isUnavailable("  ", in: [], isCatalogLoaded: true))
    }
}
