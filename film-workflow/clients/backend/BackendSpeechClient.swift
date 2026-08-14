import Foundation

enum BackendSpeechClient {
    private struct Speaker: Encodable {
        let name: String
        let voice: String
    }

    private struct AzureRequest: Encodable {
        let provider = "azure"
        let ssml: String
        let format: String
    }

    private struct GeminiRequest: Encodable {
        let provider = "gemini"
        let transcript: String
        let speakers: [Speaker]
    }

    private struct Response: Decodable {
        struct Usage: Decodable {
            let chargedPoints: Int
            let availablePoints: Int
        }
        let audioBase64: String
        let mimeType: String
        let characters: Int
        let usage: Usage
    }

    static func generateAzure(
        speakers: [NarrativeSpeaker],
        paragraphs: [NarrativeParagraph],
        format: AzureAudioFormat,
        onProgress: (@MainActor (NarrativeGenerationProgress) -> Void)? = nil
    ) async throws -> AzureTTSResponse {
        guard !speakers.isEmpty else { throw AzureTTSError.noSpeakers }
        let batches = AzureSSMLBuilder.buildBatches(speakers: speakers, paragraphs: paragraphs)
        guard !batches.isEmpty else {
            throw AzureTTSError.apiError("There is no transcript content to synthesize.")
        }

        var chunks: [Data] = []
        for (index, ssml) in batches.enumerated() {
            await onProgress?(.synthesizing(completed: index, total: batches.count, inFlight: 1))
            let response: Response = try await BackendClient.shared.post(
                "api/v1/ai/speech",
                body: AzureRequest(ssml: ssml, format: format.header),
                idempotencyKey: "speech:azure:\(UUID().uuidString)"
            )
            guard let data = Data(base64Encoded: response.audioBase64) else {
                throw AzureTTSError.invalidResponse
            }
            chunks.append(data)
            CreditBalanceStore.shared.apply(available: response.usage.availablePoints)
            onProgress?(.synthesizing(completed: index + 1, total: batches.count, inFlight: 0))
        }

        if chunks.count > 1 { onProgress?(.stitching) }
        let audio = try AzureAudioStitcher.stitch(chunks, format: format)
        return AzureTTSResponse(
            audioData: audio,
            mimeType: format.mimeType,
            fileExtension: format.fileExtension,
            ssml: AzureSSMLBuilder.build(speakers: speakers, paragraphs: paragraphs)
        )
    }

    static func generateGemini(
        transcript: String,
        speakers: [NarrativeSpeaker]
    ) async throws -> GeminiTTSResponse {
        guard !speakers.isEmpty else { throw GeminiTTSError.noSpeakers }
        let payload = speakers.prefix(2).map {
            Speaker(name: $0.displayName, voice: $0.voiceEnum.rawValue)
        }
        let response: Response = try await BackendClient.shared.post(
            "api/v1/ai/speech",
            body: GeminiRequest(transcript: transcript, speakers: payload),
            idempotencyKey: "speech:gemini:\(UUID().uuidString)"
        )
        guard let data = Data(base64Encoded: response.audioBase64) else {
            throw GeminiTTSError.invalidResponse
        }
        CreditBalanceStore.shared.apply(available: response.usage.availablePoints)
        return GeminiTTSResponse(audioData: data, mimeType: response.mimeType)
    }

    static func generateAzureSample(voiceName: String, text: String) async throws -> Data {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let ssml = """
            <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>\
            <voice name='\(voiceName)'>\(escaped)</voice></speak>
            """
        let response: Response = try await BackendClient.shared.post(
            "api/v1/ai/speech",
            body: AzureRequest(ssml: ssml, format: AzureAudioFormat.mp3.header),
            idempotencyKey: "speech-preview:azure:\(UUID().uuidString)"
        )
        guard let data = Data(base64Encoded: response.audioBase64) else {
            throw AzureTTSError.invalidResponse
        }
        CreditBalanceStore.shared.apply(available: response.usage.availablePoints)
        return data
    }

    static func generateGeminiSample(voiceName: String, text: String) async throws -> Data {
        let response: Response = try await BackendClient.shared.post(
            "api/v1/ai/speech",
            body: GeminiRequest(
                transcript: text,
                speakers: [Speaker(name: "Narrator", voice: voiceName)]
            ),
            idempotencyKey: "speech-preview:gemini:\(UUID().uuidString)"
        )
        guard let data = Data(base64Encoded: response.audioBase64) else {
            throw GeminiTTSError.invalidResponse
        }
        CreditBalanceStore.shared.apply(available: response.usage.availablePoints)
        return data
    }
}
