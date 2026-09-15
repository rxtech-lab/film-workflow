import SwiftUI
import TipKit

enum FilmWorkflowTips {
    struct AIProviderTip: Tip {
        var title: Text { Text("Add your own chat model") }
        var message: Text? {
            Text("Optional. An OpenAI-compatible endpoint adds a second engine for the agent, caption review and translation, billed by that provider instead of your credits.")
        }
        var image: Image? { Image(systemName: "sparkles") }
        var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    }

    struct AgentBackendTip: Tip {
        var title: Text { Text("Choose where AI work runs") }
        var message: Text? {
            Text("Apple Intelligence stays on device. The others use your RxFilm subscription, your own OpenAI-compatible endpoint, or a CLI you already have installed.")
        }
        var image: Image? { Image(systemName: "cpu") }
        var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    }

    struct AgentButtonTip: Tip {
        var title: Text { Text("Ask the agent to do the work") }
        var message: Text? {
            #if os(macOS)
            Text("Describe what you want in plain language; the agent operates the projects for you. ⌘⌥0 opens it any time.")
            #else
            Text("Describe what you want in plain language; the agent operates the projects for you.")
            #endif
        }
        var image: Image? { Image(systemName: "sparkles") }
        var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    }

    struct MarketplaceTip: Tip {
        var title: Text { Text("Browse the marketplace") }
        var message: Text? {
            Text("Footage, music, sound effects, fonts, transitions and Remotion prompts you can install and add to any film. ⌘⌥M opens it any time.")
        }
        var image: Image? { Image(systemName: "storefront") }
        var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    }

    struct AgentComposerTip: Tip {
        var title: Text { Text("Mention footage and use chat commands") }
        var message: Text? {
            Text("Type @ to mention footage from your film. Type / for commands such as /new, /compact or /stop. Use the target menu above to choose what this conversation works on.")
        }
        var image: Image? { Image(systemName: "scope") }
        var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    }

    struct AgentProposalTip: Tip {
        var title: Text { Text("Review before it applies") }
        var message: Text? {
            Text("Caption edits from AI arrive here as proposals you can accept or reject one by one.")
        }
        var image: Image? { Image(systemName: "checklist") }
        var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    }

    struct GenerateMusicTip: Tip {
        var title: Text { Text("Generate a take") }
        var message: Text? {
            Text("Each run keeps the previous takes, so you can compare before you commit to one.")
        }
        var image: Image? { Image(systemName: "waveform") }
        var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    }

    struct MCPServerTip: Tip {
        var title: Text { Text("Let other tools drive this app") }
        var message: Text? {
            Text("Turning this on starts a local server your editor or agent can connect to with the generated token.")
        }
        var image: Image? { Image(systemName: "network") }
        var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    }

    struct RemotionPreviewTip: Tip {
        var title: Text { Text("Preview your composition") }
        var message: Text? {
            Text("Remotion previews run in the native WebView. Source edits refresh the preview automatically.")
        }
        var image: Image? { Image(systemName: "play.rectangle") }
        var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    }

    struct SubscriptionCreditsTip: Tip {
        var title: Text { Text("Use RxFilm credits") }
        var message: Text? {
            Text("Sign in on the Account tab and add credits when needed. Images, speech, music, transcription and video all run on the RxFilm server, and each generation deducts its actual usage.")
        }
        var image: Image? { Image(systemName: "creditcard") }
        var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    }

    struct TranscribeTip: Tip {
        var title: Text { Text("Turn audio into captions") }
        var message: Text? {
            Text("Pick a provider in Settings › Captions first — on-device Whisper needs a model downloaded.")
        }
        var image: Image? { Image(systemName: "captions.bubble") }
        var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    }

    struct WhisperModelTip: Tip {
        var title: Text { Text("Transcribe without sending audio anywhere") }
        var message: Text? {
            Text("Download a Whisper model once and captions are generated entirely on this device.")
        }
        var image: Image? { Image(systemName: "lock.shield") }
        var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    }
}
