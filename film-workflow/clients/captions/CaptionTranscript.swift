import Foundation

/// The provider-neutral transcription result.
///
/// Port of `debate-bot/internal/stt/stt.go`. Every provider normalizes onto
/// these types so cue building, validation and alignment never branch on which
/// backend produced the data.

/// One word (or CJK glyph) with its position on the audio timeline.
nonisolated struct CaptionWordTiming: Sendable, Hashable {
    var text: String
    var offsetMs: Int
    var durationMs: Int
    var confidence: Double = 0

    var endMs: Int { offsetMs + durationMs }

    init(text: String, offsetMs: Int, durationMs: Int, confidence: Double = 0) {
        self.text = text
        self.offsetMs = offsetMs
        self.durationMs = durationMs
        self.confidence = confidence
    }
}

/// One diarized utterance.
nonisolated struct CaptionPhrase: Sendable, Hashable {
    /// 1-based diarization speaker id; 0 means unknown or not diarized.
    var speaker: Int = 0
    var offsetMs: Int
    var durationMs: Int
    var text: String

    /// Detected BCP-47 language, when the provider reports one (Azure does,
    /// Gemini doesn't).
    var locale: String = ""

    /// Optional: Azure fast transcription and Whisper supply these; Gemini's
    /// prompted transcription does not, and cue building falls back to
    /// proportional splitting when empty.
    var words: [CaptionWordTiming] = []

    var endMs: Int { offsetMs + durationMs }

    init(
        speaker: Int = 0,
        offsetMs: Int,
        durationMs: Int,
        text: String,
        locale: String = "",
        words: [CaptionWordTiming] = []
    ) {
        self.speaker = speaker
        self.offsetMs = offsetMs
        self.durationMs = durationMs
        self.text = text
        self.locale = locale
        self.words = words
    }
}

nonisolated struct CaptionTranscript: Sendable {
    var durationMs: Int
    var phrases: [CaptionPhrase]
    var providerName: String = ""
    var detectedLanguage: String = ""

    /// True when at least one phrase carries word timings.
    var hasWordTimings: Bool { phrases.contains { !$0.words.isEmpty } }

    /// Every word across every phrase, in timeline order. The hypothesis side
    /// of narrative alignment.
    var allWords: [CaptionWordTiming] {
        phrases.flatMap(\.words).sorted { $0.offsetMs < $1.offsetMs }
    }

    /// Distinct provider speaker numbers, ascending. Drives the initial
    /// speaker roster for diarized providers.
    var speakerNumbers: [Int] {
        Array(Set(phrases.map(\.speaker))).sorted()
    }

    init(
        durationMs: Int,
        phrases: [CaptionPhrase],
        providerName: String = "",
        detectedLanguage: String = ""
    ) {
        self.durationMs = durationMs
        self.phrases = phrases
        self.providerName = providerName
        self.detectedLanguage = detectedLanguage
    }
}

/// One transcription job.
nonisolated struct CaptionTranscribeRequest: Sendable {
    /// Local file. HTTP providers stream it from disk; WhisperKit reads it
    /// directly.
    var audioURL: URL
    var mimeType: String
    var sizeBytes: Int

    /// Pre-probed via `AudioProbe` so providers that don't report a duration
    /// still produce a bounded transcript.
    var durationMs: Int

    /// BCP-47 hint; empty means auto-detect.
    var languageHint: String = ""

    var maxSpeakers: Int = 2
    var diarizationEnabled: Bool = true
    var wordTimestampsEnabled: Bool = true

    init(
        audioURL: URL,
        mimeType: String,
        sizeBytes: Int,
        durationMs: Int,
        languageHint: String = "",
        maxSpeakers: Int = 2,
        diarizationEnabled: Bool = true,
        wordTimestampsEnabled: Bool = true
    ) {
        self.audioURL = audioURL
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.durationMs = durationMs
        self.languageHint = languageHint
        self.maxSpeakers = maxSpeakers
        self.diarizationEnabled = diarizationEnabled
        self.wordTimestampsEnabled = wordTimestampsEnabled
    }
}

/// Azure diarization accepts 2…35 speakers; the same bound is applied to every
/// provider so a project's setting means the same thing everywhere.
/// Port of `stt.ClampMaxSpeakers`.
nonisolated func clampCaptionMaxSpeakers(_ n: Int) -> Int {
    min(max(n, 2), 35)
}
