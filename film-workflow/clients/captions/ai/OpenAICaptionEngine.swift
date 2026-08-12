import Foundation

/// Runs caption AI tasks against any OpenAI-compatible chat endpoint.
///
/// Structure comes from `response_format: json_schema` where the gateway
/// supports it, with a plain-text fallback for the many that don't — that
/// fallback is not optional in practice: proxies routinely accept the field and
/// ignore it, or reject the request outright.
nonisolated struct OpenAICaptionEngine: CaptionAIEngine {
    var backend: AgentBackend { .openAICompatible }

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

    // MARK: - Translate

    func translate(_ request: CaptionTranslateRequest) async throws -> CaptionTranslateResult {
        guard !request.lines.isEmpty else { return CaptionTranslateResult(lines: []) }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "lines": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "number": ["type": "integer"],
                            "text": ["type": "string"],
                        ],
                        "required": ["number", "text"],
                        "additionalProperties": false,
                    ],
                ]
            ],
            "required": ["lines"],
            "additionalProperties": false,
        ]

        let json = try await complete(
            instructions: CaptionAIPrompts.translateInstructions(
                source: request.sourceLanguage,
                target: request.targetLanguage
            ),
            prompt: CaptionAIPrompts.translatePrompt(request),
            schemaName: "caption_translation",
            schema: schema
        )

        let rows = (json["lines"] as? [[String: Any]]) ?? []
        return CaptionTranslateResult(
            lines: rows.compactMap { row in
                guard let number = intValue(row["number"]),
                      let text = row["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return CaptionTranslatedLine(number: number, text: text)
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

        let reply: OpenAIAssistantResponse
        do {
            reply = try await OpenAIClient.chatWithTools(
                messages: messages,
                tools: [],
                endpoint: endpoint,
                apiKey: apiKey,
                model: model,
                extraBody: structured
            )
        } catch {
            // Only a gateway feature gap is worth asking twice. Re-sending an
            // over-long prompt verbatim just spends another request to fail the
            // same way, and reporting the second failure hides the first — which
            // is how a context-length error used to reach the user disguised as
            // a malformed reply.
            guard !isContextLimit(error) else {
                throw CaptionAIError.contextOverflow(error.localizedDescription)
            }
            guard CaptionAIRetryPolicy.isWorthSplitting(error) else { throw error }

            do {
                reply = try await OpenAIClient.chatWithTools(
                    messages: [
                        OpenAIRichMessage(
                            role: "system",
                            content: instructions
                                + "\n\nReply with JSON only, matching this shape:\n"
                                + describe(schema)
                        ),
                        OpenAIRichMessage(role: "user", content: prompt),
                    ],
                    tools: [],
                    endpoint: endpoint,
                    apiKey: apiKey,
                    model: model
                )
            } catch {
                // The fallback's own failure says nothing the first one didn't.
                throw error
            }
        }

        // A completion cut off at the token cap is not a bad answer, it is half
        // an answer — and the only fix is to ask about fewer lines.
        if reply.finishReason == "length" {
            throw CaptionAIError.contextOverflow("the reply was cut off before it finished")
        }

        guard let content = reply.content, !content.isEmpty else {
            throw CaptionAIError.emptyResponse
        }
        guard let object = Self.parseJSONObject(content) else {
            // JSON that opens and never closes is a truncated reply wearing a
            // parse error's clothes; say so, so the caller retries smaller.
            if Self.looksTruncated(content) {
                throw CaptionAIError.contextOverflow("the reply was cut off mid-JSON")
            }
            throw CaptionAIError.malformedResponse(String(content.prefix(200)))
        }
        return object
    }

    /// Whether a transport error is the provider saying "you sent too much".
    private func isContextLimit(_ error: any Error) -> Bool {
        switch error {
        case OpenAIError.httpError(413, _):
            return true
        case let OpenAIError.httpError(_, body):
            return CaptionAIRetryPolicy.mentionsContextLimit(body ?? "")
        case let OpenAIError.apiError(message):
            return CaptionAIRetryPolicy.mentionsContextLimit(message)
        default:
            return false
        }
    }

    /// An unparseable reply that opened a brace it never closed.
    static func looksTruncated(_ raw: String) -> Bool {
        let opens = raw.count(where: { $0 == "{" })
        let closes = raw.count(where: { $0 == "}" })
        return opens > closes
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
