import Foundation

/// Runs caption AI tasks against any OpenAI-compatible chat endpoint.
///
/// Structure comes from `response_format: json_schema` where the gateway
/// supports it, with a plain-text fallback for the many that don't — that
/// fallback is not optional in practice: proxies routinely accept the field and
/// ignore it, or reject the request outright.
nonisolated struct OpenAICaptionEngine: CaptionAIEngine {
    var backend: CaptionAIBackend { .openAICompatible }

    let endpoint: String
    let apiKey: String
    let model: String

    /// The model id, which is what the user actually chose — "OpenAI-compatible
    /// model" would tell them nothing they didn't already know.
    var modelLabel: String {
        model.trimmingCharacters(in: .whitespaces).isEmpty ? backend.engineLabel : model
    }

    // MARK: - Split

    func planSplit(_ request: CaptionSplitRequest) async throws -> CaptionSplitPlan {
        // One marked-up string rather than an array of pieces: an array invites
        // weaker models to answer with one element per word, which is exactly
        // how the shredding bug reached users.
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "markedLine": [
                    "type": "string",
                    "description": "The line copied through word for word, with a | inserted at each break point. Usually exactly one. No | at all means leave the line alone.",
                ],
                "reason": ["type": "string"],
            ],
            "required": ["markedLine"],
            "additionalProperties": false,
        ]

        let json = try await complete(
            instructions: CaptionAIPrompts.splitInstructions(
                maxRunes: request.maxRunes,
                minRunes: request.minRunes,
                maxPieces: request.maxPieces
            ),
            prompt: CaptionAIPrompts.splitPrompt(request),
            schemaName: "caption_split",
            schema: schema
        )

        guard let marked = json["markedLine"] as? String, !marked.isEmpty else {
            throw CaptionAIError.emptyResponse
        }
        return CaptionSplitPlan.parse(
            markedLine: marked,
            reason: json["reason"] as? String ?? ""
        )
    }

    // MARK: - Terms

    func reviewTerms(_ request: CaptionTermReviewRequest) async throws -> CaptionTermReviewResult {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "fixes": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "number": ["type": "integer"],
                            "correctedText": ["type": "string"],
                        ],
                        "required": ["number", "correctedText"],
                        "additionalProperties": false,
                    ],
                ]
            ],
            "required": ["fixes"],
            "additionalProperties": false,
        ]

        let json = try await complete(
            instructions: CaptionAIPrompts.termReviewInstructions,
            prompt: CaptionAIPrompts.termReviewPrompt(request),
            schemaName: "caption_term_review",
            schema: schema
        )

        let fixes = (json["fixes"] as? [[String: Any]]) ?? []
        return CaptionTermReviewResult(
            corrections: fixes.compactMap { fix in
                guard let number = intValue(fix["number"]),
                      let text = fix["correctedText"] as? String else { return nil }
                return CaptionTermCorrection(number: number, correctedText: text)
            }
        )
    }

    // MARK: - Chat

    func converse(_ request: CaptionChatRequest) async throws -> CaptionChatReply {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "reply": ["type": "string"],
                "edits": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "number": ["type": "integer"],
                            "kind": [
                                "type": "string",
                                "enum": ["replaceText", "split", "mergeWithNext", "delete"],
                            ],
                            "pieces": ["type": "array", "items": ["type": "string"]],
                        ],
                        "required": ["number", "kind"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["reply"],
            "additionalProperties": false,
        ]

        let json = try await complete(
            instructions: CaptionAIPrompts.chatInstructions,
            prompt: CaptionAIPrompts.chatPrompt(request),
            schemaName: "caption_chat",
            schema: schema
        )

        let edits = (json["edits"] as? [[String: Any]]) ?? []
        return CaptionChatReply(
            assistantText: json["reply"] as? String ?? "",
            edits: edits.compactMap { edit in
                guard let number = intValue(edit["number"]),
                      let rawKind = edit["kind"] as? String,
                      let kind = CaptionChatEdit.Kind(rawValue: rawKind) else { return nil }
                let pieces = (edit["pieces"] as? [Any])?.compactMap { $0 as? String } ?? []
                return CaptionChatEdit(number: number, kind: kind, pieces: pieces)
            }
        )
    }

    // MARK: - Transport

    /// One chat completion returning a JSON object.
    ///
    /// Tries strict structured output first, then retries without it. Reusing
    /// `chatWithTools` rather than `chat` is what makes that possible: it is the
    /// only entry point that accepts `extraBody`.
    private func complete(
        instructions: String,
        prompt: String,
        schemaName: String,
        schema: [String: Any]
    ) async throws -> [String: Any] {
        let messages = [
            OpenAIRichMessage(role: "system", content: instructions),
            OpenAIRichMessage(role: "user", content: prompt),
        ]

        let structured: [String: Any] = [
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": schemaName,
                    "strict": true,
                    "schema": schema,
                ],
            ]
        ]

        var content: String?
        do {
            content = try await OpenAIClient.chatWithTools(
                messages: messages,
                tools: [],
                endpoint: endpoint,
                apiKey: apiKey,
                model: model,
                extraBody: structured
            ).content
        } catch {
            // Gateways that don't implement json_schema reject the whole
            // request. Ask again in plain JSON mode rather than failing the
            // user's action over a proxy's feature gap.
            content = try await OpenAIClient.chatWithTools(
                messages: [
                    OpenAIRichMessage(
                        role: "system",
                        content: instructions + "\n\nReply with JSON only, matching this shape:\n"
                            + describe(schema)
                    ),
                    OpenAIRichMessage(role: "user", content: prompt),
                ],
                tools: [],
                endpoint: endpoint,
                apiKey: apiKey,
                model: model
            ).content
        }

        guard let content, !content.isEmpty else { throw CaptionAIError.emptyResponse }
        guard let object = Self.parseJSONObject(content) else {
            throw CaptionAIError.malformedResponse(String(content.prefix(200)))
        }
        return object
    }

    /// Pulls a JSON object out of a reply that may be fenced or prefixed.
    ///
    /// Models wrap JSON in ```json fences or a sentence of preamble often enough
    /// that a strict parse would fail on otherwise perfect answers.
    static func parseJSONObject(_ raw: String) -> [String: Any]? {
        func object(from text: some StringProtocol) -> [String: Any]? {
            guard let data = String(text).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = object(from: trimmed) { return direct }

        // Widest brace pair — handles both fences and prose on either side.
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else { return nil }
        return object(from: trimmed[start...end])
    }

    /// A compact textual rendering of the schema, for the no-`response_format`
    /// fallback.
    private func describe(_ schema: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: schema,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// JSON numbers arrive as `Int`, `Double` or `NSNumber` depending on the
    /// gateway; and some models return the number as a string.
    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let double as Double: return Int(double)
        case let string as String: return Int(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}
