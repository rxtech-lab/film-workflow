import Foundation

/// Decoder for Gemini's structured transcription reply.
///
/// The request itself now runs on the RxFilm server (`api/v1/ai/transcriptions`
/// with `provider=gemini`), which holds the Google key and owns the prompt and
/// response schema. The reply is Gemini's own `generateContent` envelope, so
/// the parsing stays here where the caption types live.
///
/// Two limits are inherent to this approach and shape the rest of the feature:
/// it returns **no word timings**, and its phrase offsets are model-estimated,
/// so they can be non-monotonic. `CaptionTranscriptValidator.validateTiming`
/// plus the configured timing-fallback provider exist for exactly this.
nonisolated enum GeminiTranscriptionClient {
    static let defaultModel = "gemini-2.5-flash"

    static func decode(_ data: Data, fallbackDurationMs: Int) throws -> CaptionTranscript {
        struct Envelope: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }
        struct Payload: Decodable {
            struct Phrase: Decodable {
                let speaker: Int?
                let offsetMs: Int?
                let durationMs: Int?
                let text: String?
            }
            let durationMs: Int?
            let phrases: [Phrase]?
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let json = envelope.candidates?.first?.content?.parts?
                  .compactMap(\.text).joined(),
              !json.isEmpty
        else {
            throw CaptionTranscriberError.invalidResponse(
                provider: "Gemini",
                detail: CaptionHTTP.truncate(String(decoding: data, as: UTF8.self), 400)
            )
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else {
            throw CaptionTranscriberError.invalidResponse(
                provider: "Gemini", detail: CaptionHTTP.truncate(json, 400)
            )
        }

        let phrases = (payload.phrases ?? []).compactMap { phrase -> CaptionPhrase? in
            let text = (phrase.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return CaptionPhrase(
                speaker: phrase.speaker ?? 0,
                offsetMs: max(phrase.offsetMs ?? 0, 0),
                durationMs: max(phrase.durationMs ?? 0, 0),
                text: text
                // No words: Gemini does not report word timings.
            )
        }
        guard !phrases.isEmpty else { throw CaptionTranscriberError.noSpeechFound }

        let duration = payload.durationMs.flatMap { $0 > 0 ? $0 : nil }
            ?? max(fallbackDurationMs, phrases.map(\.endMs).max() ?? 0)

        return CaptionTranscript(
            durationMs: duration,
            phrases: phrases,
            providerName: CaptionProvider.gemini.rawValue
        )
    }
}
