import Foundation
import Testing

@testable import film_workflow

/// Response-shape tests for the cloud providers.
///
/// The Azure payload is the trimmed real response from
/// `debate-bot/internal/stt/azure_test.go`, including its CJK per-glyph words —
/// the shape most likely to break a port.
@Suite("Caption provider decoding")
struct CaptionProviderDecodeTests {

    // MARK: - Azure

    private let azureJSON = """
    {
      "durationMilliseconds": 182439,
      "combinedPhrases": [{"channel": 0, "text": "Good afternoon. 欢迎大家。"}],
      "phrases": [
        {
          "channel": 0, "speaker": 1, "offsetMilliseconds": 960, "durationMilliseconds": 640,
          "text": "Good afternoon.", "locale": "en-US", "confidence": 0.93,
          "words": [
            {"text": "Good", "offsetMilliseconds": 960, "durationMilliseconds": 240},
            {"text": "afternoon.", "offsetMilliseconds": 1200, "durationMilliseconds": 400}
          ]
        },
        {
          "channel": 0, "speaker": 2, "offsetMilliseconds": 10080, "durationMilliseconds": 24920,
          "text": "欢迎大家。", "locale": "zh-CN", "confidence": 0.9,
          "words": [
            {"text": "欢", "offsetMilliseconds": 10080, "durationMilliseconds": 120},
            {"text": "迎", "offsetMilliseconds": 10200, "durationMilliseconds": 120},
            {"text": "大", "offsetMilliseconds": 10320, "durationMilliseconds": 120},
            {"text": "家。", "offsetMilliseconds": 10440, "durationMilliseconds": 120}
          ]
        }
      ]
    }
    """

    @Test("Azure fast transcription decodes phrases, speakers and word timings")
    func decodeAzure() throws {
        let transcript = try AzureFastTranscriptionClient.decode(
            Data(azureJSON.utf8), fallbackDurationMs: 0
        )

        #expect(transcript.durationMs == 182_439)
        #expect(transcript.phrases.count == 2)
        #expect(transcript.hasWordTimings)
        #expect(transcript.speakerNumbers == [1, 2])
        #expect(transcript.detectedLanguage == "en-US")

        let cjk = transcript.phrases[1]
        #expect(cjk.speaker == 2)
        #expect(cjk.text == "欢迎大家。")
        #expect(cjk.locale == "zh-CN")
        #expect(cjk.words.count == 4)
        // Punctuation stays attached to the final glyph, as Azure sends it.
        #expect(cjk.words.last?.text == "家。")
        #expect(cjk.words.last?.offsetMs == 10_440)
    }

    @Test("Azure timings from the fixture pass validation")
    func azureFixtureValidates() throws {
        let transcript = try AzureFastTranscriptionClient.decode(
            Data(azureJSON.utf8), fallbackDurationMs: 0
        )
        try CaptionTranscriptValidator.validateTiming(transcript)
    }

    @Test("Azure decode fails cleanly on an empty phrase list")
    func azureNoSpeech() {
        let json = #"{"durationMilliseconds": 1000, "phrases": []}"#
        #expect(throws: CaptionTranscriberError.self) {
            _ = try AzureFastTranscriptionClient.decode(Data(json.utf8), fallbackDurationMs: 0)
        }
    }

    @Test("Azure decode reports a readable error for a non-JSON body")
    func azureGarbage() {
        #expect(throws: CaptionTranscriberError.self) {
            _ = try AzureFastTranscriptionClient.decode(
                Data("<html>502 Bad Gateway</html>".utf8), fallbackDurationMs: 0
            )
        }
    }

    // MARK: - OpenAI

    @Test("verbose_json decodes segments and attaches words, converting seconds to ms")
    func decodeOpenAIVerboseJSON() throws {
        let json = """
        {
          "task": "transcribe",
          "language": "english",
          "duration": 2.5,
          "text": "Good afternoon. Hello there.",
          "segments": [
            {"id": 0, "start": 0.96, "end": 1.6, "text": " Good afternoon."},
            {"id": 1, "start": 1.7, "end": 2.5, "text": " Hello there."}
          ],
          "words": [
            {"word": "Good", "start": 0.96, "end": 1.2},
            {"word": "afternoon", "start": 1.2, "end": 1.6},
            {"word": "Hello", "start": 1.7, "end": 2.1},
            {"word": "there", "start": 2.1, "end": 2.5}
          ]
        }
        """
        let transcript = try OpenAITranscriptionClient.decodeVerboseJSON(
            Data(json.utf8), fallbackDurationMs: 0
        )

        #expect(transcript.durationMs == 2500)
        #expect(transcript.phrases.count == 2)
        // Seconds → milliseconds happens exactly once, at the decode boundary.
        #expect(transcript.phrases[0].offsetMs == 960)
        #expect(transcript.phrases[0].durationMs == 640)
        #expect(transcript.phrases[0].text == "Good afternoon.")
        // Words are bucketed into the segment that contains them.
        #expect(transcript.phrases[0].words.map(\.text) == ["Good", "afternoon"])
        #expect(transcript.phrases[1].words.map(\.text) == ["Hello", "there"])
        // No diarization from this endpoint.
        #expect(transcript.phrases.allSatisfy { $0.speaker == 0 })
    }

    @Test("A text-only response still yields one phrase")
    func decodeOpenAITextOnly() throws {
        // Some gateways implement verbose_json only partially.
        let json = #"{"text": "Just the text.", "duration": 3.0}"#
        let transcript = try OpenAITranscriptionClient.decodeVerboseJSON(
            Data(json.utf8), fallbackDurationMs: 5000
        )
        #expect(transcript.phrases.count == 1)
        #expect(transcript.phrases[0].text == "Just the text.")
        #expect(transcript.durationMs == 3000)
    }

    @Test("An empty transcription is reported as no speech")
    func decodeOpenAIEmpty() {
        #expect(throws: CaptionTranscriberError.self) {
            _ = try OpenAITranscriptionClient.decodeVerboseJSON(
                Data(#"{"text": "", "duration": 1.0}"#.utf8), fallbackDurationMs: 0
            )
        }
    }

    @Test("gpt-4o transcribe models are known not to carry word timings")
    func modelWordTimingSupport() {
        #expect(OpenAITranscriptionClient.modelSupportsWordTimings("whisper-1"))
        #expect(OpenAITranscriptionClient.modelSupportsWordTimings("openai/whisper-1"))
        #expect(!OpenAITranscriptionClient.modelSupportsWordTimings("gpt-4o-transcribe"))
        #expect(!OpenAITranscriptionClient.modelSupportsWordTimings("openai/gpt-4o-mini-transcribe"))
    }

    // MARK: - Model capability filtering

    @Test("A declared type settles whether a model transcribes")
    func transcriptionModelDeclaredType() {
        // `speech` means text-to-speech; offering tts-1 as a transcriber was the
        // bug this filter exists to prevent.
        #expect(!OpenAIModelInfo(id: "tts-1", type: "speech", tags: nil).isTranscriptionModel)
        #expect(!OpenAIModelInfo(id: "openai/tts-1-hd", type: "speech", tags: nil).isTranscriptionModel)

        #expect(OpenAIModelInfo(id: "some-house-model", type: "transcription", tags: nil)
            .isTranscriptionModel)
        #expect(OpenAIModelInfo(id: "openai/whisper-1", type: "transcription", tags: nil)
            .isTranscriptionModel)

        // A declared type outranks the name, in both directions.
        #expect(!OpenAIModelInfo(id: "whisper-image-remix", type: "image", tags: nil)
            .isTranscriptionModel)
        #expect(!OpenAIModelInfo(id: "gpt-4o-transcribe-chat", type: "language", tags: nil)
            .isTranscriptionModel)
    }

    @Test("Untyped endpoints fall back to the id heuristic")
    func transcriptionModelHeuristic() {
        #expect(OpenAIModelInfo(id: "whisper-1", type: nil, tags: nil).isTranscriptionModel)
        #expect(OpenAIModelInfo(id: "gpt-4o-transcribe", type: nil, tags: nil).isTranscriptionModel)
        #expect(OpenAIModelInfo(id: "grok-stt", type: nil, tags: nil).isTranscriptionModel)

        #expect(!OpenAIModelInfo(id: "tts-1", type: nil, tags: nil).isTranscriptionModel)
        #expect(!OpenAIModelInfo(id: "gpt-5", type: nil, tags: nil).isTranscriptionModel)

        // Tags are consulted before the name.
        #expect(OpenAIModelInfo(id: "house-asr", type: nil, tags: ["speech-to-text"])
            .isTranscriptionModel)
    }

    // MARK: - Gemini

    @Test("Gemini structured output is unwrapped from the candidate envelope")
    func decodeGemini() throws {
        let inner = """
        {"durationMs": 5000, "phrases": [\
        {"speaker": 1, "offsetMs": 0, "durationMs": 2000, "text": "Good afternoon."},\
        {"speaker": 2, "offsetMs": 2500, "durationMs": 2000, "text": "欢迎大家。"}]}
        """
        let envelope: [String: Any] = [
            "candidates": [["content": ["parts": [["text": inner]]]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        let transcript = try GeminiTranscriptionClient.decode(data, fallbackDurationMs: 0)

        #expect(transcript.durationMs == 5000)
        #expect(transcript.phrases.count == 2)
        #expect(transcript.speakerNumbers == [1, 2])
        // Gemini never returns word timings — this is what pushes narrative
        // alignment into its estimated tier.
        #expect(!transcript.hasWordTimings)
    }

    @Test("Gemini's backwards-timestamp failure mode is caught by validation")
    func geminiNonMonotonicIsRejected() throws {
        let inner = """
        {"durationMs": 10000, "phrases": [\
        {"speaker": 1, "offsetMs": 5000, "durationMs": 1000, "text": "Later."},\
        {"speaker": 1, "offsetMs": 1000, "durationMs": 1000, "text": "Earlier."}]}
        """
        let envelope: [String: Any] = [
            "candidates": [["content": ["parts": [["text": inner]]]]]
        ]
        let transcript = try GeminiTranscriptionClient.decode(
            try JSONSerialization.data(withJSONObject: envelope), fallbackDurationMs: 0
        )

        #expect(throws: CaptionTimingError.self) {
            try CaptionTranscriptValidator.validateTiming(transcript)
        }

        // …and the repair path makes it publishable when no fallback exists.
        let repaired = CaptionTranscriptionService.repairTiming(transcript)
        try CaptionTranscriptValidator.validateTiming(repaired)
    }

    @Test("A refusal or empty candidate list surfaces as an invalid response")
    func geminiEmptyCandidates() {
        #expect(throws: CaptionTranscriberError.self) {
            _ = try GeminiTranscriptionClient.decode(
                Data(#"{"candidates": []}"#.utf8), fallbackDurationMs: 0
            )
        }
    }

    // MARK: - Chunk merging

    @Test("Chunked transcripts are shifted onto one timeline")
    func mergeChunks() {
        let first = CaptionTranscript(
            durationMs: 1000,
            phrases: [CaptionPhrase(
                speaker: 0, offsetMs: 100, durationMs: 500, text: "First.",
                words: [CaptionWordTiming(text: "First.", offsetMs: 100, durationMs: 500)]
            )]
        )
        let second = CaptionTranscript(
            durationMs: 1000,
            phrases: [CaptionPhrase(
                speaker: 0, offsetMs: 200, durationMs: 500, text: "Second.",
                words: [CaptionWordTiming(text: "Second.", offsetMs: 200, durationMs: 500)]
            )]
        )

        let merged = CaptionAudioChunker.merge(
            [(first, 0), (second, 60_000)],
            totalDurationMs: 120_000,
            providerName: "test"
        )

        #expect(merged.phrases.count == 2)
        #expect(merged.phrases[0].offsetMs == 100)
        // The second chunk's phrase and its words both shift by the chunk start.
        #expect(merged.phrases[1].offsetMs == 60_200)
        #expect(merged.phrases[1].words[0].offsetMs == 60_200)
        #expect(merged.durationMs == 120_000)
    }

    // MARK: - Model selection

    @Test("A per-project OpenAI model wins over the app-wide one")
    @MainActor func openAITranscriptionModelPrecedence() {
        var config = AppConfig()
        config.subscriptionTranscriptionModel = "gpt-4o-transcribe"

        let project = CaptionProject(name: "P")
        let settings = CaptionSettings.shared

        // No override: fall back to the app-wide model.
        #expect(
            CaptionTranscriptionService
                .options(for: .openAI, config: config, settings: settings, project: project)
                .model == "gpt-4o-transcribe"
        )

        // Override set: it wins.
        project.openAITranscriptionModelOverride = "whisper-1"
        #expect(
            CaptionTranscriptionService
                .options(for: .openAI, config: config, settings: settings, project: project)
                .model == "whisper-1"
        )

        // Neither set: left empty so the client's own `whisper-1` default applies.
        config.subscriptionTranscriptionModel = ""
        project.openAITranscriptionModelOverride = ""
        #expect(
            CaptionTranscriptionService
                .options(for: .openAI, config: config, settings: settings, project: project)
                .model.isEmpty
        )
    }

    @Test("A configured model is only sent to the provider it belongs to")
    func transcriptionModelResolution() {
        let catalog = [
            PickableModel(id: "whisper-1", provider: "openai", displayName: "Whisper", capability: "transcription", estimate: nil),
            PickableModel(id: "gemini-2.5-flash", provider: "google", displayName: "Gemini", capability: "transcription", estimate: nil),
        ]

        // A Gemini id configured app-wide must not be sent to the Whisper route.
        #expect(
            BackendTranscriptionClient.resolvedModel(
                for: "openai", configured: "gemini-2.5-flash",
                fallback: "whisper-1", catalog: catalog
            ) == "whisper-1"
        )
        // …and the matching provider keeps it.
        #expect(
            BackendTranscriptionClient.resolvedModel(
                for: "google", configured: "gemini-2.5-flash",
                fallback: "gemini-2.5-flash", catalog: catalog
            ) == "gemini-2.5-flash"
        )
        // An id the catalog has never heard of falls back to the provider's
        // first catalog entry rather than being sent blind.
        #expect(
            BackendTranscriptionClient.resolvedModel(
                for: "google", configured: "made-up",
                fallback: "gemini-2.5-flash", catalog: catalog
            ) == "gemini-2.5-flash"
        )
        // With no catalog at all, an id that looks like the provider's is kept.
        #expect(
            BackendTranscriptionClient.resolvedModel(
                for: "google", configured: "gemini-3-pro",
                fallback: "gemini-2.5-flash", catalog: []
            ) == "gemini-3-pro"
        )
    }

    // MARK: - Speaker roster

    @Test("Diarized speaker numbers become a named roster")
    @MainActor func syncSpeakersFromDiarizedTranscript() {
        let project = CaptionProject(name: "P")
        let transcript = CaptionTranscript(
            durationMs: 1000,
            phrases: [
                CaptionPhrase(speaker: 1, offsetMs: 0, durationMs: 500, text: "A"),
                CaptionPhrase(speaker: 2, offsetMs: 500, durationMs: 500, text: "B"),
            ]
        )
        CaptionTranscriptionService.syncSpeakers(of: project, from: transcript)

        #expect(project.speakers.count == 2)
        #expect(project.speakers.map(\.label) == ["Speaker 1", "Speaker 2"])
        #expect(project.speakers.map(\.providerSpeakerNumber) == [1, 2])
    }

    @Test("Re-syncing keeps labels the user already renamed")
    @MainActor func syncSpeakersPreservesRenames() {
        let project = CaptionProject(name: "P")
        project.speakers = [CaptionSpeaker(label: "Alice", providerSpeakerNumber: 1)]

        CaptionTranscriptionService.syncSpeakers(
            of: project,
            from: CaptionTranscript(
                durationMs: 1000,
                phrases: [
                    CaptionPhrase(speaker: 1, offsetMs: 0, durationMs: 500, text: "A"),
                    CaptionPhrase(speaker: 2, offsetMs: 500, durationMs: 500, text: "B"),
                ]
            )
        )

        #expect(project.speakers.count == 2)
        #expect(project.speakers[0].label == "Alice")
        #expect(project.speakers[1].label == "Speaker 2")
    }

    @Test("Undiarized output still gets one speaker to assign")
    @MainActor func syncSpeakersUndiarized() {
        let project = CaptionProject(name: "P")
        CaptionTranscriptionService.syncSpeakers(
            of: project,
            from: CaptionTranscript(
                durationMs: 1000,
                phrases: [CaptionPhrase(speaker: 0, offsetMs: 0, durationMs: 500, text: "A")]
            )
        )
        #expect(project.speakers.count == 1)
    }
}
