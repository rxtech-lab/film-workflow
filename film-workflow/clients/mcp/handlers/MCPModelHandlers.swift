import Foundation

/// The models this account may generate with.
///
/// The catalog is curated server-side and changes without the app shipping, so
/// a model id is not something to know in advance — it is something to read.
/// Without this tool the only way to name one is to guess, and a guess comes
/// back as "This model is not available for the selected capability" with no
/// hint of what would have worked.
@MainActor
enum MCPModelHandlers {
    static let descriptors: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: "models_list",
            description: "The generation models this account may use, with the credits each costs per unit. Read this before setting an item's model — the ids are curated per account and change without the app updating. Capabilities: image (footage_update's subscriptionModel on an image item), video, chat, speech, music, transcription. Music and narration have no model to choose. The entry flagged `isDefault` is what an item with no model set will use.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "capability": [
                        "type": "string",
                        "enum": AICapability.allCases.map(\.rawValue),
                        "description": "Which kind of generation to list. Omit for every capability."
                    ] as [String: Any],
                    "refresh": [
                        "type": "boolean",
                        "description": "Re-read the catalog from the server instead of the hour-long cache. Use after a model was rejected."
                    ] as [String: Any],
                ]
            ]
        )
    ]

    static let toolNames: Set<String> = Set(descriptors.map(\.name))

    static func canHandle(_ name: String) -> Bool { toolNames.contains(name) }

    static func handle(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard name == "models_list" else {
            throw MCPToolError.invalidArguments("unrecognized: \(name)")
        }
        let refresh = arguments["refresh"] as? Bool ?? false
        let capabilities: [AICapability]
        if let raw = arguments["capability"] as? String {
            guard let capability = AICapability(rawValue: raw) else {
                throw MCPToolError.invalidArguments(
                    "unknown capability \"\(raw)\"; one of \(AICapability.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            capabilities = [capability]
        } else {
            capabilities = AICapability.allCases
        }

        var models: [[String: Any]] = []
        for capability in capabilities {
            // One failure must not hide the capabilities that did answer: the
            // catalog is fetched whole and filtered per capability, so this is
            // at most one round trip however many are asked for.
            let listed = (try? await BackendModelCatalog.shared.models(
                capability: capability,
                forceRefresh: refresh
            )) ?? []
            models.append(contentsOf: listed.map(payload))
        }
        return MCPToolRegistry.jsonResult([
            "models": models,
            "note": models.isEmpty
                ? "No models are listed. Sign in with show_sign_in_dialog, or the account has no curated models for these capabilities."
                : "Use `id` verbatim when setting a model."
        ] as [String: Any])
    }

    private static func payload(_ model: PickableModel) -> [String: Any] {
        var row: [String: Any] = [
            "id": model.id,
            "provider": model.provider,
            "displayName": model.displayName,
            "capability": model.capability,
        ]
        if let estimate = model.estimate {
            row["creditsPerUnit"] = estimate.pointsPerUnit
            row["unit"] = estimate.unit
        }
        if model.isPreferred { row["isDefault"] = true }
        return row
    }
}
