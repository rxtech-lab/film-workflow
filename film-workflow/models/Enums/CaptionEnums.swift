import Foundation
import SwiftUI

/// Which speech-to-text backend produces a caption project's timings.
nonisolated enum CaptionProvider: String, CaseIterable, Codable, Identifiable {
    case whisperLocal = "WhisperKit"
    case openAI = "OpenAI"
    case azure = "Azure"
    case gemini = "Gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperLocal: return "Whisper (on device)"
        case .openAI: return "OpenAI-compatible"
        case .azure: return "Azure Speech"
        case .gemini: return "Gemini"
        }
    }

    /// True when the provider itself separates speakers. Whisper and the
    /// OpenAI transcription endpoint do not — everything lands on speaker 0
    /// and has to be assigned by hand in the editor.
    var supportsDiarization: Bool {
        switch self {
        case .azure, .gemini: return true
        case .whisperLocal, .openAI: return false
        }
    }

    /// True when the provider returns per-word timings. Gemini's prompted
    /// transcription returns phrase offsets only, which forces narrative
    /// alignment down to its estimated tier.
    var supportsWordTimings: Bool {
        switch self {
        case .azure, .openAI, .whisperLocal: return true
        case .gemini: return false
        }
    }

    var requiresNetwork: Bool { self != .whisperLocal }

    /// Providers suitable for narrative caption alignment, where only the
    /// timings are taken from ASR. Word timings are what make that work, so
    /// Gemini is a poor fit even though it transcribes well.
    var recommendedForNarrativeAlignment: Bool { supportsWordTimings }

    var systemImage: String {
        switch self {
        case .whisperLocal: return "cpu"
        case .openAI: return "cloud"
        case .azure: return "waveform.badge.mic"
        case .gemini: return "sparkles"
        }
    }
}

/// Where a caption project's audio came from.
nonisolated enum CaptionSourceKind: String, CaseIterable, Codable, Identifiable {
    case importedFile
    case generatedNarrative

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .importedFile: return "Imported file"
        case .generatedNarrative: return "Narrative project"
        }
    }
}

/// How much to trust a narrative caption project's timings.
///
/// Set by `CaptionAligner` when reference text is aligned against an ASR
/// hypothesis. Drives the warning banner in the editor.
nonisolated enum CaptionAlignmentQuality: String, CaseIterable, Codable, Identifiable {
    /// Not a narrative project, or never aligned.
    case none
    /// Per-word anchors matched; word timings are as measured.
    case wordAligned
    /// Too few word anchors to trust individually; sentence spans are real
    /// but the words inside them are interpolated.
    case sentenceAnchored
    /// No usable anchors. Timings are proportional guesses from text length.
    case estimated

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Not aligned"
        case .wordAligned: return "Word aligned"
        case .sentenceAnchored: return "Sentence aligned"
        case .estimated: return "Estimated"
        }
    }

    /// True when the user should be nudged toward the retimer.
    var needsReview: Bool {
        switch self {
        case .sentenceAnchored, .estimated: return true
        case .none, .wordAligned: return false
        }
    }
}

nonisolated enum CaptionExportFormat: String, CaseIterable, Codable, Identifiable {
    case vtt
    case srt
    case text
    case json

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vtt: return "WebVTT"
        case .srt: return "SubRip"
        case .text: return "Plain text"
        case .json: return "JSON"
        }
    }

    var fileExtension: String {
        switch self {
        case .vtt: return "vtt"
        case .srt: return "srt"
        case .text: return "txt"
        case .json: return "json"
        }
    }

    var contentType: String {
        switch self {
        case .vtt: return "text/vtt; charset=utf-8"
        case .srt: return "application/x-subrip; charset=utf-8"
        case .text: return "text/plain; charset=utf-8"
        case .json: return "application/json"
        }
    }

    /// Only WebVTT has a standard inline word-timing syntax.
    var supportsWordKaraoke: Bool { self == .vtt }

    /// Only WebVTT has `<v Speaker>` voice spans.
    var supportsSpeakerVoiceTags: Bool { self == .vtt }
}

nonisolated enum CaptionExportGranularity: String, CaseIterable, Codable, Identifiable {
    /// One cue per segment.
    case sentence
    /// One cue per word.
    case word
    /// One cue per segment with inline `<00:00:01.234>` word timings (VTT only).
    case wordKaraoke

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sentence: return "Sentence"
        case .word: return "Word"
        case .wordKaraoke: return "Word (karaoke)"
        }
    }
}

/// How a caption that runs past the length limit gets broken up.
nonisolated enum CaptionSplitMode: String, CaseIterable, Codable, Identifiable {
    /// Cut as soon as the character count is reached — fast, deterministic, and
    /// indifferent to where the sentence actually breaks.
    case characterLimit
    /// Ask a language model where the line should break, or whether it should
    /// break at all.
    case ai

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .characterLimit: return "By character count"
        case .ai: return "With AI"
        }
    }
}
