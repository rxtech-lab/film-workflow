import Foundation

enum GeminiTTSError: LocalizedError {
    case noAPIKey
    case noSpeakers
    case invalidResponse
    case apiError(String)
    case noAudioInResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No Google AI API key configured. Please set it in Settings."
        case .noSpeakers:
            return "Add at least one speaker before generating."
        case .invalidResponse:
            return "Invalid response from the API."
        case .apiError(let message):
            return "API error: \(message)"
        case .noAudioInResponse:
            return "No audio data found in the API response."
        case .httpError(let code):
            return "HTTP error: \(code)"
        }
    }
}

struct GeminiTTSResponse {
    let audioData: Data
    let mimeType: String
}

struct GeminiTTSClient {
    private static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent"
    private static let sampleRate: UInt32 = 24_000
    private static let channels: UInt16 = 1
    private static let bitsPerSample: UInt16 = 16

    static func generate(
        transcript: String,
        speakers: [NarrativeSpeaker],
        apiKey: String
    ) async throws -> GeminiTTSResponse {
        guard !apiKey.isEmpty else { throw GeminiTTSError.noAPIKey }
        guard !speakers.isEmpty else { throw GeminiTTSError.noSpeakers }

        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let speechConfig: [String: Any]
        if speakers.count == 1 {
            let voice = speakers[0].voiceEnum.rawValue
            speechConfig = [
                "voiceConfig": [
                    "prebuiltVoiceConfig": ["voiceName": voice]
                ]
            ]
        } else {
            let configs: [[String: Any]] = speakers.prefix(2).map { speaker in
                [
                    "speaker": speaker.displayName,
                    "voiceConfig": [
                        "prebuiltVoiceConfig": ["voiceName": speaker.voiceEnum.rawValue]
                    ]
                ]
            }
            speechConfig = [
                "multiSpeakerVoiceConfig": [
                    "speakerVoiceConfigs": configs
                ]
            ]
        }

        let body: [String: Any] = [
            "contents": [["parts": [["text": transcript]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": speechConfig
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw GeminiTTSError.apiError(message)
            }
            throw GeminiTTSError.httpError(httpResponse.statusCode)
        }

        return try parseResponse(data)
    }

    static func generateSample(
        voiceName: String,
        apiKey: String,
        text: String = "Hello! This is how I sound."
    ) async throws -> GeminiTTSResponse {
        guard !apiKey.isEmpty else { throw GeminiTTSError.noAPIKey }

        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "contents": [["parts": [["text": text]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": ["voiceName": voiceName]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw GeminiTTSError.apiError(message)
            }
            throw GeminiTTSError.httpError(httpResponse.statusCode)
        }

        return try parseResponse(data)
    }

    private static func parseResponse(_ data: Data) throws -> GeminiTTSResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            print("[GeminiTTSClient] Invalid response. Raw body:\n\(raw)")
            throw GeminiTTSError.invalidResponse
        }

        var pcmData: Data?

        for part in parts {
            if let inlineData = part["inlineData"] as? [String: Any],
               let base64String = inlineData["data"] as? String,
               let decoded = Data(base64Encoded: base64String) {
                pcmData = decoded
            }
        }

        guard let pcm = pcmData else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            print("[GeminiTTSClient] No audio in response. Raw body:\n\(raw)")
            throw GeminiTTSError.noAudioInResponse
        }

        let wav = wrapPCMAsWAV(pcm, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample)
        return GeminiTTSResponse(audioData: wav, mimeType: "audio/wav")
    }

    private static func wrapPCMAsWAV(
        _ pcm: Data,
        sampleRate: UInt32,
        channels: UInt16,
        bitsPerSample: UInt16
    ) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(pcm.count)
        let riffChunkSize = 36 + dataSize

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(UInt32LE(riffChunkSize))
        header.append("WAVE".data(using: .ascii)!)

        header.append("fmt ".data(using: .ascii)!)
        header.append(UInt32LE(16))                 // Subchunk1Size (PCM)
        header.append(UInt16LE(1))                  // AudioFormat = PCM
        header.append(UInt16LE(channels))
        header.append(UInt32LE(sampleRate))
        header.append(UInt32LE(byteRate))
        header.append(UInt16LE(blockAlign))
        header.append(UInt16LE(bitsPerSample))

        header.append("data".data(using: .ascii)!)
        header.append(UInt32LE(dataSize))

        var out = Data()
        out.append(header)
        out.append(pcm)
        return out
    }

    private static func UInt32LE(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: MemoryLayout<UInt32>.size)
    }

    private static func UInt16LE(_ value: UInt16) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: MemoryLayout<UInt16>.size)
    }
}
