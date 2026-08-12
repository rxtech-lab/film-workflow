import Foundation
import Observation

/// App-wide caption defaults.
///
/// These are preferences, not secrets, so they live in UserDefaults — the
/// `MCPSettings` pattern. Provider credentials and model ids stay in
/// `AppConfig` (Keychain).
@MainActor
@Observable
final class CaptionSettings {
    static let shared = CaptionSettings()

    /// Provider used when a caption project doesn't override it.
    var defaultProvider: CaptionProvider {
        didSet {
            guard defaultProvider != oldValue else { return }
            UserDefaults.standard.set(defaultProvider.rawValue, forKey: Keys.defaultProvider)
        }
    }

    /// Provider used for narrative captions, where only the timings come from
    /// ASR. Defaults to Azure because word timings are what make alignment
    /// work, and Gemini doesn't return them.
    var narrativeProvider: CaptionProvider {
        didSet {
            guard narrativeProvider != oldValue else { return }
            UserDefaults.standard.set(narrativeProvider.rawValue, forKey: Keys.narrativeProvider)
        }
    }

    /// Provider to retry with when the primary returns timings that fail
    /// validation (non-monotonic offsets, spans past the audio end). Gemini's
    /// prompted timestamps routinely need this. `nil` disables the fallback.
    var timingFallbackProvider: CaptionProvider? {
        didSet {
            guard timingFallbackProvider != oldValue else { return }
            UserDefaults.standard.set(timingFallbackProvider?.rawValue ?? "", forKey: Keys.timingFallbackProvider)
        }
    }

    /// WhisperKit model variant to load, e.g. `openai_whisper-base`.
    var whisperVariant: String {
        didSet {
            guard whisperVariant != oldValue else { return }
            UserDefaults.standard.set(whisperVariant, forKey: Keys.whisperVariant)
        }
    }

    /// BCP-47 language hint applied to new projects. Empty means auto-detect.
    var defaultLanguageHint: String {
        didSet {
            guard defaultLanguageHint != oldValue else { return }
            UserDefaults.standard.set(defaultLanguageHint, forKey: Keys.defaultLanguageHint)
        }
    }

    var defaultMaxSpeakers: Int {
        didSet {
            guard defaultMaxSpeakers != oldValue else { return }
            UserDefaults.standard.set(defaultMaxSpeakers, forKey: Keys.defaultMaxSpeakers)
        }
    }

    /// Maximum grapheme clusters in one sentence cue before it is split.
    var maxCueRunes: Int {
        didSet {
            guard maxCueRunes != oldValue else { return }
            UserDefaults.standard.set(maxCueRunes, forKey: Keys.maxCueRunes)
        }
    }

    /// How captions that run past `maxCueRunes` get broken up.
    var splitMode: CaptionSplitMode {
        didSet {
            guard splitMode != oldValue else { return }
            UserDefaults.standard.set(splitMode.rawValue, forKey: Keys.splitMode)
        }
    }

    /// Engine used for caption AI work — splitting, glossary review, and the
    /// assistant's opening backend.
    var aiBackend: CaptionAIBackend {
        didSet {
            guard aiBackend != oldValue else { return }
            UserDefaults.standard.set(aiBackend.rawValue, forKey: Keys.aiBackend)
        }
    }

    /// Show the review sheet before AI changes are written. Applies to the
    /// automatic pass after transcription; manual passes always review.
    var aiConfirmChanges: Bool {
        didSet {
            guard aiConfirmChanges != oldValue else { return }
            UserDefaults.standard.set(aiConfirmChanges, forKey: Keys.aiConfirmChanges)
        }
    }

    /// Pass the project's glossary to the speech provider as a spelling hint,
    /// so fewer mistakes exist for the AI review to find.
    var termsBiasTranscription: Bool {
        didSet {
            guard termsBiasTranscription != oldValue else { return }
            UserDefaults.standard.set(termsBiasTranscription, forKey: Keys.termsBiasTranscription)
        }
    }

    /// Match ratio at or above which narrative alignment keeps per-word
    /// anchors. Below it, alignment degrades to sentence anchoring.
    var narrativeAlignmentMinConfidence: Double {
        didSet {
            guard narrativeAlignmentMinConfidence != oldValue else { return }
            UserDefaults.standard.set(narrativeAlignmentMinConfidence, forKey: Keys.narrativeAlignmentMinConfidence)
        }
    }

    /// Keep the Whisper pipe resident between transcriptions. Loading a large
    /// model takes 10–60 s, but it holds up to 1.6 GB.
    var keepWhisperModelLoaded: Bool {
        didSet {
            guard keepWhisperModelLoaded != oldValue else { return }
            UserDefaults.standard.set(keepWhisperModelLoaded, forKey: Keys.keepWhisperModelLoaded)
        }
    }

    private init() {
        let defaults = UserDefaults.standard

        let storedProvider = defaults.string(forKey: Keys.defaultProvider) ?? ""
        self.defaultProvider = CaptionProvider(rawValue: storedProvider) ?? .azure

        let storedNarrative = defaults.string(forKey: Keys.narrativeProvider) ?? ""
        self.narrativeProvider = CaptionProvider(rawValue: storedNarrative) ?? .azure

        let storedFallback = defaults.string(forKey: Keys.timingFallbackProvider)
        // A stored empty string means "explicitly disabled"; a missing key
        // means "never configured", which defaults to Azure.
        if let storedFallback {
            self.timingFallbackProvider = CaptionProvider(rawValue: storedFallback)
        } else {
            self.timingFallbackProvider = .azure
        }

        self.whisperVariant = defaults.string(forKey: Keys.whisperVariant) ?? ""
        self.defaultLanguageHint = defaults.string(forKey: Keys.defaultLanguageHint) ?? ""

        let storedMaxSpeakers = defaults.integer(forKey: Keys.defaultMaxSpeakers)
        self.defaultMaxSpeakers = storedMaxSpeakers == 0 ? 2 : storedMaxSpeakers

        let storedMaxRunes = defaults.integer(forKey: Keys.maxCueRunes)
        self.maxCueRunes = storedMaxRunes == 0 ? 80 : storedMaxRunes

        let storedSplitMode = defaults.string(forKey: Keys.splitMode) ?? ""
        self.splitMode = CaptionSplitMode(rawValue: storedSplitMode) ?? .characterLimit

        let storedBackend = defaults.string(forKey: Keys.aiBackend) ?? ""
        self.aiBackend = CaptionAIBackend(rawValue: storedBackend) ?? .appleIntelligence

        // Both default to on for a *missing* key, so `bool(forKey:)`'s false
        // default can't silently opt an existing user out.
        if defaults.object(forKey: Keys.aiConfirmChanges) == nil {
            defaults.set(true, forKey: Keys.aiConfirmChanges)
        }
        self.aiConfirmChanges = defaults.bool(forKey: Keys.aiConfirmChanges)

        if defaults.object(forKey: Keys.termsBiasTranscription) == nil {
            defaults.set(true, forKey: Keys.termsBiasTranscription)
        }
        self.termsBiasTranscription = defaults.bool(forKey: Keys.termsBiasTranscription)

        let storedConfidence = defaults.double(forKey: Keys.narrativeAlignmentMinConfidence)
        self.narrativeAlignmentMinConfidence = storedConfidence == 0 ? 0.75 : storedConfidence

        if defaults.object(forKey: Keys.keepWhisperModelLoaded) == nil {
            defaults.set(true, forKey: Keys.keepWhisperModelLoaded)
        }
        self.keepWhisperModelLoaded = defaults.bool(forKey: Keys.keepWhisperModelLoaded)
    }

    private enum Keys {
        static let defaultProvider = "caption.defaultProvider"
        static let narrativeProvider = "caption.narrativeProvider"
        static let timingFallbackProvider = "caption.timingFallbackProvider"
        static let whisperVariant = "caption.whisperVariant"
        static let defaultLanguageHint = "caption.defaultLanguageHint"
        static let defaultMaxSpeakers = "caption.defaultMaxSpeakers"
        static let maxCueRunes = "caption.maxCueRunes"
        static let splitMode = "caption.splitMode"
        static let aiBackend = "caption.aiBackend"
        static let aiConfirmChanges = "caption.aiConfirmChanges"
        static let termsBiasTranscription = "caption.termsBiasTranscription"
        static let narrativeAlignmentMinConfidence = "caption.narrativeAlignmentMinConfidence"
        static let keepWhisperModelLoaded = "caption.keepWhisperModelLoaded"
    }
}
