import Foundation

/// Decoder for the OpenAI `verbose_json` transcription reply.
///
/// The request runs on the RxFilm server (`api/v1/ai/transcriptions` with
/// `provider=openai`), which holds the key; what stays here is the parsing and
/// the model facts the caption UI needs.
///
/// Returns word and segment timings, but has **no** diarization — every phrase
/// comes back on speaker 0 and speakers must be assigned in the editor.
nonisolated enum OpenAITranscriptionClient {
    static let defaultModel = "whisper-1"

    /// OpenAI's `gpt-4o*-transcribe` models don't implement `verbose_json`, so
    /// they return no timings however they're asked.
    static func modelSupportsWordTimings(_ model: String) -> Bool {
        !model.lowercased().contains("gpt-4o")
    }

    // MARK: - Decoding

    private struct Response: Decodable {
        struct Segment: Decodable {
            let start: Double?
            let end: Double?
            let text: String?
        }
        struct Word: Decodable {
            let word: String?
            let start: Double?
            let end: Double?
        }
        let text: String?
        let language: String?
        let duration: Double?
        let segments: [Segment]?
        let words: [Word]?
    }

    /// `verbose_json` reports **seconds as floats**; everything downstream is
    /// integer milliseconds, so convert at this boundary and nowhere else.
    static func decodeVerboseJSON(_ data: Data, fallbackDurationMs: Int) throws -> CaptionTranscript {
        let document: Response
        do {
            document = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CaptionTranscriberError.invalidResponse(
                provider: "OpenAI",
                detail: CaptionHTTP.truncate(String(decoding: data, as: UTF8.self), 400)
            )
        }

        func ms(_ seconds: Double?) -> Int? {
            guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
            return Int((seconds * 1000).rounded())
        }

        let allWords: [CaptionWordTiming] = (document.words ?? []).compactMap { word in
            guard let text = word.word, !text.isEmpty,
                  let start = ms(word.start), let end = ms(word.end), end > start
            else { return nil }
            return CaptionWordTiming(text: text, offsetMs: start, durationMs: end - start)
        }

        var phrases: [CaptionPhrase] = []

        if let segments = document.segments, !segments.isEmpty {
            for segment in segments {
                let text = (segment.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let start = ms(segment.start), let end = ms(segment.end), end > start else {
                    continue
                }
                guard !text.isEmpty else { continue }
                // Attach the words that fall inside this segment so cue building
                // can split on real word boundaries.
                let words = allWords.filter { $0.offsetMs >= start && $0.endMs <= end }
                phrases.append(CaptionPhrase(
                    speaker: 0, // no diarization
                    offsetMs: start,
                    durationMs: end - start,
                    text: text,
                    locale: document.language ?? "",
                    words: words
                ))
            }
        } else if let text = document.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty {
            // Some gateways honour verbose_json only partially and return plain
            // text; treat the whole file as one phrase rather than failing.
            let duration = ms(document.duration) ?? fallbackDurationMs
            phrases.append(CaptionPhrase(
                speaker: 0,
                offsetMs: 0,
                durationMs: max(duration, 1),
                text: text,
                locale: document.language ?? "",
                words: allWords
            ))
        }

        guard !phrases.isEmpty else { throw CaptionTranscriberError.noSpeechFound }

        let duration = ms(document.duration)
            ?? max(fallbackDurationMs, phrases.map(\.endMs).max() ?? 0)

        return CaptionTranscript(
            durationMs: duration,
            phrases: phrases,
            providerName: CaptionProvider.openAI.rawValue,
            detectedLanguage: document.language ?? ""
        )
    }
}
