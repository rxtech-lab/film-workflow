import Foundation
import Testing

@testable import film_workflow

/// Downloads a real model to verify the download lifecycle end to end.
///
/// This exists because of a specific bug: WhisperKit's progress callback hops to
/// the main actor through unordered detached tasks, so a trailing 100% update
/// could land *after* the completion handler cleared `downloadProgress` and pin
/// the row at "Downloading — 100%" forever. Only a real download exercises that
/// ordering, so this test pulls the smallest model (~75 MB) rather than faking it.
/// Opt-in only. These tests download ~75 MB, write into the real
/// `Application Support/.../whisper` folder, and mutate the saved model
/// selection — and two parallel test-runner processes sharing that folder trip
/// over each other. Run deliberately:
///
///     WHISPER_DOWNLOAD_TESTS=1 xcodebuild test -parallel-testing-enabled NO \
///       -only-testing:film-workflowTests/WhisperDownloadIntegrationTests ...
@Suite(
    "Whisper download lifecycle",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["WHISPER_DOWNLOAD_TESTS"] == "1",
        "set WHISPER_DOWNLOAD_TESTS=1 to run; downloads a real model"
    )
)
struct WhisperDownloadIntegrationTests {

    private static let variant = "openai_whisper-tiny"

    @Test("A completed download clears progress and reports installed", .timeLimit(.minutes(5)))
    @MainActor
    func downloadCompletesCleanly() async throws {
        let store = WhisperModelStore.shared
        await store.fetchIfNeeded()

        try #require(
            store.models.contains { $0.variant == Self.variant },
            "catalog must offer \(Self.variant); skipping means the network is unavailable"
        )

        await store.download(Self.variant)

        if let error = store.lastError {
            // Network failures aren't this test's subject, but the UI must not be
            // left mid-download either.
            #expect(store.downloadProgress[Self.variant] == nil,
                    "a failed download must still clear its progress entry")
            Issue.record("download failed (network?): \(error)")
            return
        }

        // The bug: this stayed at 1.0 forever.
        #expect(store.downloadProgress[Self.variant] == nil,
                "progress must be cleared once the download finishes")

        // Give any straggler progress callbacks a chance to land and resurrect it.
        try await Task.sleep(for: .milliseconds(750))
        #expect(store.downloadProgress[Self.variant] == nil,
                "a late progress callback must not resurrect the progress entry")

        #expect(WhisperModelStore.isInstalled(variant: Self.variant))
        let entry = store.models.first { $0.variant == Self.variant }
        #expect(entry?.isInstalled == true, "the row must flip to installed")
        #expect((entry?.installedBytes ?? 0) > 0, "installed size must be reported")

        // First download auto-selects, so the provider is usable immediately.
        #expect(!CaptionSettings.shared.whisperVariant.isEmpty)

        // And the engine can actually load what was downloaded.
        try await WhisperKitEngine.shared.ensureLoaded(variant: Self.variant)
        #expect(await WhisperKitEngine.shared.isLoaded)
        await WhisperKitEngine.shared.unload()
    }

    @Test("An installed model resolves to a folder and loads", .timeLimit(.minutes(3)))
    @MainActor
    func installedModelLoads() async throws {
        // Regression: the engine used to pass only `downloadBase`, which
        // WhisperKit treats purely as a download destination. With
        // `download: false` its own `modelFolder` stayed nil and loading failed
        // with "Model folder is not set." — so the folder must be resolved here
        // and handed over explicitly.
        let variant = try #require(
            WhisperModelStore.installedVariants().sorted().first,
            "requires at least one downloaded model"
        )

        let folder = try #require(WhisperModelStore.folderURL(for: variant))
        #expect(FileManager.default.fileExists(atPath: folder.path))

        try await WhisperKitEngine.shared.ensureLoaded(variant: variant)
        #expect(await WhisperKitEngine.shared.isLoaded)
        #expect(await WhisperKitEngine.shared.currentVariant == variant)
        await WhisperKitEngine.shared.unload()
    }

    @Test("Deleting removes it from disk and clears the selection")
    @MainActor
    func deleteRemovesModel() async throws {
        let store = WhisperModelStore.shared
        try #require(
            WhisperModelStore.isInstalled(variant: Self.variant),
            "requires the download test to have run first"
        )

        CaptionSettings.shared.whisperVariant = Self.variant
        store.delete(Self.variant)

        #expect(!WhisperModelStore.isInstalled(variant: Self.variant))
        #expect(CaptionSettings.shared.whisperVariant.isEmpty,
                "deleting the selected model must clear the selection")
    }

    @Test("Loading a model that isn't downloaded fails instead of downloading it")
    @MainActor
    func missingModelDoesNotSilentlyDownload() async {
        // Downloading gigabytes as a side effect of transcribing would be a nasty
        // surprise, so the engine must refuse.
        await #expect(throws: CaptionTranscriberError.self) {
            try await WhisperKitEngine.shared.ensureLoaded(
                variant: "openai_whisper-large-v3-does-not-exist"
            )
        }
    }
}
