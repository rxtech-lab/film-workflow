import Foundation

/// Decoder for Azure Speech **fast transcription** — diarized and word-timed.
///
/// The request runs on the RxFilm server (`api/v1/ai/transcriptions` with
/// `provider=azure`), which holds the key; the documented per-request limits
/// stay here because the client checks them before uploading.
nonisolated enum AzureFastTranscriptionClient {
    /// Documented per-request limits for the fast transcription endpoint.
    static let maxBytes = 300 * 1024 * 1024
    static let maxDurationMs = 2 * 60 * 60 * 1000

    // MARK: - Decoding

    private struct Response: Decodable {
        struct Phrase: Decodable {
            struct Word: Decodable {
                let text: String?
                let offsetMilliseconds: Int?
                let durationMilliseconds: Int?
            }
            let speaker: Int?
            let offsetMilliseconds: Int?
            let durationMilliseconds: Int?
            let text: String?
            let locale: String?
            let confidence: Double?
            let words: [Word]?
        }
        let durationMilliseconds: Int?
        let phrases: [Phrase]?
    }

    static func decode(_ data: Data, fallbackDurationMs: Int) throws -> CaptionTranscript {
        let document: Response
        do {
            document = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CaptionTranscriberError.invalidResponse(
                provider: "Azure",
                detail: CaptionHTTP.truncate(String(decoding: data, as: UTF8.self), 400)
            )
        }

        let phrases = (document.phrases ?? []).compactMap { phrase -> CaptionPhrase? in
            let text = (phrase.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let words = (phrase.words ?? []).compactMap { word -> CaptionWordTiming? in
                guard let wordText = word.text, !wordText.isEmpty,
                      let offset = word.offsetMilliseconds,
                      let duration = word.durationMilliseconds
                else { return nil }
                return CaptionWordTiming(text: wordText, offsetMs: offset, durationMs: duration)
            }
            guard !text.isEmpty || !words.isEmpty else { return nil }

            return CaptionPhrase(
                // Azure reports 0 for non-diarized audio; the caption speaker
                // roster treats 0 as unknown, which is the right meaning.
                speaker: phrase.speaker ?? 0,
                offsetMs: phrase.offsetMilliseconds ?? 0,
                durationMs: phrase.durationMilliseconds ?? 0,
                text: text,
                locale: phrase.locale ?? "",
                words: words
            )
        }

        guard !phrases.isEmpty else { throw CaptionTranscriberError.noSpeechFound }

        let duration = document.durationMilliseconds.flatMap { $0 > 0 ? $0 : nil }
            ?? max(fallbackDurationMs, phrases.map(\.endMs).max() ?? 0)

        return CaptionTranscript(
            durationMs: duration,
            phrases: phrases.sorted { $0.offsetMs < $1.offsetMs },
            providerName: CaptionProvider.azure.rawValue,
            detectedLanguage: phrases.first { !$0.locale.isEmpty }?.locale ?? ""
        )
    }
}
