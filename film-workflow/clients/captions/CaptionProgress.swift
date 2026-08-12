import Foundation
import SwiftUI

/// Coarse progress for a transcription run.
///
/// An enum rather than a `fraction`-carrying struct (the `RemotionRenderer`
/// shape) because the phases are genuinely heterogeneous: a model download has
/// a real fraction, a synchronous Azure call has only elapsed time, and the
/// aligner reports its own. Modeled on `NarrativeGenerationProgress`.
nonisolated enum CaptionProgress: Sendable, Equatable {
    /// Probing duration, converting format, or chunking.
    case preparing(detail: String)
    /// WhisperKit only.
    case downloadingModel(name: String, fraction: Double)
    /// WhisperKit only — loading a large model takes 10–60 s.
    case loadingModel(name: String)
    /// HTTP providers, streaming the audio up.
    case uploading(bytesSent: Int64, totalBytes: Int64)
    /// The provider is working and reports nothing until it finishes.
    case waitingForProvider(elapsedSeconds: Int)
    /// Local decoding, or one chunk of a chunked upload.
    case transcribing(chunk: Int, totalChunks: Int, fraction: Double?)
    /// Matching ASR timings onto the narrative reference text.
    case aligning(fraction: Double)
    case buildingCues
    /// An AI engine is choosing where the over-long captions should break.
    ///
    /// Carries the engine's name because the one that runs isn't always the one
    /// in Settings — availability can force a fallback — and a run that takes
    /// minutes shouldn't leave the user guessing which model is spending them.
    case reviewingWithAI(engine: String, done: Int, total: Int)
    /// Translating the active transcript into one target language.
    ///
    /// `inFlight` is how many captions are currently out with the engine. It
    /// matters because a batch is atomic: a short transcript is one request, so
    /// `done` stays at zero for the whole run and a bar driven by it alone reads
    /// as stuck when the work is in fact underway.
    case translating(done: Int, total: Int, language: String, inFlight: Int = 0)

    /// Determinate progress where we have it; nil drives an indeterminate bar.
    var fraction: Double? {
        switch self {
        case .downloadingModel(_, let fraction):
            return fraction
        case .uploading(let sent, let total):
            guard total > 0 else { return nil }
            return min(max(Double(sent) / Double(total), 0), 1)
        case .transcribing(let chunk, let total, let fraction):
            if let fraction { return min(max(fraction, 0), 1) }
            guard total > 1 else { return nil }
            return min(max(Double(chunk) / Double(total), 0), 1)
        case .aligning(let fraction):
            return min(max(fraction, 0), 1)
        case .reviewingWithAI(_, let done, let total):
            guard total > 0 else { return nil }
            return min(max(Double(done) / Double(total), 0), 1)
        case .translating(let done, let total, _, let inFlight):
            guard total > 0 else { return nil }
            // Nothing finished yet but a request is out: indeterminate, because
            // 0% and "stuck" look identical and only one of them is true.
            guard done > 0 || inFlight == 0 else { return nil }
            return min(max(Double(done) / Double(total), 0), 1)
        case .preparing, .loadingModel, .waitingForProvider, .buildingCues:
            return nil
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .preparing: return "Preparing audio…"
        case .downloadingModel: return "Downloading model…"
        case .loadingModel: return "Loading model…"
        case .uploading: return "Uploading audio…"
        case .waitingForProvider: return "Transcribing…"
        case .transcribing: return "Transcribing…"
        case .aligning: return "Aligning to your script…"
        case .buildingCues: return "Building captions…"
        case .reviewingWithAI: return "Choosing where to break captions…"
        case .translating: return "Translating captions…"
        }
    }

    var detail: String {
        switch self {
        case .preparing(let detail):
            return detail
        case .downloadingModel(let name, let fraction):
            return "\(name) — \(Int(fraction * 100))%"
        case .loadingModel(let name):
            return name
        case .uploading(let sent, let total):
            guard total > 0 else { return Self.byteText(sent) }
            return "\(Self.byteText(sent)) of \(Self.byteText(total))"
        case .waitingForProvider(let elapsed):
            return elapsed >= 60
                ? "\(elapsed / 60)m \(elapsed % 60)s elapsed"
                : "\(elapsed)s elapsed"
        case .transcribing(let chunk, let total, _):
            return total > 1 ? "Part \(chunk) of \(total)" : ""
        case .aligning(let fraction):
            return "\(Int(fraction * 100))%"
        case .buildingCues:
            return ""
        case .reviewingWithAI(let engine, let done, let total):
            let count = total > 0 ? "\(done) of \(total)" : ""
            guard !engine.isEmpty else { return count }
            return count.isEmpty ? engine : "\(engine) · \(count)"
        case .translating(let done, let total, let language, let inFlight):
            var count = total > 0 ? "\(done) of \(total)" : ""
            // Named so a single-request run says what it is waiting on rather
            // than repeating a number that cannot move until it returns.
            if inFlight > 0 {
                let working = "translating \(inFlight)…"
                count = count.isEmpty ? working : "\(count) · \(working)"
            }
            guard !language.isEmpty else { return count }
            return count.isEmpty ? language : "\(language) · \(count)"
        }
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Per-run provider configuration resolved from `AppConfig` + `CaptionSettings`.
///
/// Passed separately from `CaptionTranscribeRequest` (which describes the
/// audio) so a caller can retry the same audio on a different provider without
/// rebuilding the request.
nonisolated struct CaptionProviderOptions: Sendable {
    /// Model id for providers that take one (OpenAI, Gemini) or the WhisperKit
    /// variant for local transcription.
    var model: String = ""

    /// The project's glossary, comma-separated, offered to providers that
    /// accept a spelling hint. Empty when the project has no terms or the user
    /// turned the hint off.
    ///
    /// This is a *bias*, not a constraint: providers weight these spellings more
    /// heavily but can still mishear them, which is why the AI review pass
    /// exists as well.
    var termsHint: String = ""

    init(model: String = "", termsHint: String = "") {
        self.model = model
        self.termsHint = termsHint
    }
}
