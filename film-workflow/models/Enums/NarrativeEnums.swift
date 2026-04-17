import Foundation
import SwiftUI

enum NarrativeProvider: String, CaseIterable, Codable, Identifiable {
    case gemini = "Gemini"
    case azure = "Azure"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var isSupported: Bool {
        switch self {
        case .gemini: return true
        case .azure: return true
        }
    }

    var maxSpeakers: Int? {
        switch self {
        case .gemini: return 2
        case .azure: return nil
        }
    }
}

enum AzureAudioFormat: String, CaseIterable, Codable, Identifiable {
    case mp3
    case wav

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mp3: return "MP3"
        case .wav: return "WAV"
        }
    }

    var header: String {
        switch self {
        case .mp3: return "audio-24khz-48kbitrate-mono-mp3"
        case .wav: return "riff-24khz-16bit-mono-pcm"
        }
    }

    var fileExtension: String { rawValue }

    var mimeType: String {
        switch self {
        case .mp3: return "audio/mp3"
        case .wav: return "audio/wav"
        }
    }
}

enum GeminiVoice: String, CaseIterable, Codable, Identifiable {
    case zephyr = "Zephyr"
    case puck = "Puck"
    case charon = "Charon"
    case kore = "Kore"
    case fenrir = "Fenrir"
    case leda = "Leda"
    case orus = "Orus"
    case aoede = "Aoede"
    case callirrhoe = "Callirrhoe"
    case autonoe = "Autonoe"
    case enceladus = "Enceladus"
    case iapetus = "Iapetus"
    case umbriel = "Umbriel"
    case algieba = "Algieba"
    case despina = "Despina"
    case erinome = "Erinome"
    case algenib = "Algenib"
    case rasalgethi = "Rasalgethi"
    case laomedeia = "Laomedeia"
    case achernar = "Achernar"
    case alnilam = "Alnilam"
    case schedar = "Schedar"
    case gacrux = "Gacrux"
    case pulcherrima = "Pulcherrima"
    case achird = "Achird"
    case zubenelgenubi = "Zubenelgenubi"
    case vindemiatrix = "Vindemiatrix"
    case sadachbia = "Sadachbia"
    case sadaltager = "Sadaltager"
    case sulafat = "Sulafat"

    var id: String { rawValue }

    var vibe: String {
        switch self {
        case .zephyr: return "Bright"
        case .puck: return "Upbeat"
        case .charon: return "Informative"
        case .kore: return "Firm"
        case .fenrir: return "Excitable"
        case .leda: return "Youthful"
        case .orus: return "Firm"
        case .aoede: return "Breezy"
        case .callirrhoe: return "Easy-going"
        case .autonoe: return "Bright"
        case .enceladus: return "Breathy"
        case .iapetus: return "Clear"
        case .umbriel: return "Easy-going"
        case .algieba: return "Smooth"
        case .despina: return "Smooth"
        case .erinome: return "Clear"
        case .algenib: return "Gravelly"
        case .rasalgethi: return "Informative"
        case .laomedeia: return "Upbeat"
        case .achernar: return "Soft"
        case .alnilam: return "Firm"
        case .schedar: return "Even"
        case .gacrux: return "Mature"
        case .pulcherrima: return "Forward"
        case .achird: return "Friendly"
        case .zubenelgenubi: return "Casual"
        case .vindemiatrix: return "Gentle"
        case .sadachbia: return "Lively"
        case .sadaltager: return "Knowledgeable"
        case .sulafat: return "Warm"
        }
    }

    var displayName: String { "\(rawValue) — \(vibe)" }

    var localizedVibe: LocalizedStringKey {
        switch self {
        case .zephyr: "Bright"
        case .puck: "Upbeat"
        case .charon: "Informative"
        case .kore: "Firm"
        case .fenrir: "Excitable"
        case .leda: "Youthful"
        case .orus: "Firm"
        case .aoede: "Breezy"
        case .callirrhoe: "Easy-going"
        case .autonoe: "Bright"
        case .enceladus: "Breathy"
        case .iapetus: "Clear"
        case .umbriel: "Easy-going"
        case .algieba: "Smooth"
        case .despina: "Smooth"
        case .erinome: "Clear"
        case .algenib: "Gravelly"
        case .rasalgethi: "Informative"
        case .laomedeia: "Upbeat"
        case .achernar: "Soft"
        case .alnilam: "Firm"
        case .schedar: "Even"
        case .gacrux: "Mature"
        case .pulcherrima: "Forward"
        case .achird: "Friendly"
        case .zubenelgenubi: "Casual"
        case .vindemiatrix: "Gentle"
        case .sadachbia: "Lively"
        case .sadaltager: "Knowledgeable"
        case .sulafat: "Warm"
        }
    }

    var localizedDisplayName: LocalizedStringKey {
        "\(rawValue) — \(Text(localizedVibe))"
    }
}

enum AzureRole: String, CaseIterable, Identifiable, Codable {
    case none = ""
    case girl = "Girl"
    case boy = "Boy"
    case youngAdultFemale = "YoungAdultFemale"
    case youngAdultMale = "YoungAdultMale"
    case olderAdultFemale = "OlderAdultFemale"
    case olderAdultMale = "OlderAdultMale"
    case seniorFemale = "SeniorFemale"
    case seniorMale = "SeniorMale"

    var id: String { rawValue }
    var displayName: String { rawValue.isEmpty ? "Default" : rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .none: "Default"
        case .girl: "Girl"
        case .boy: "Boy"
        case .youngAdultFemale: "Young Adult Female"
        case .youngAdultMale: "Young Adult Male"
        case .olderAdultFemale: "Older Adult Female"
        case .olderAdultMale: "Older Adult Male"
        case .seniorFemale: "Senior Female"
        case .seniorMale: "Senior Male"
        }
    }
}

enum AzureProsodyPreset {
    static let pitchSuggestions = ["", "x-low", "low", "medium", "high", "x-high", "+10%", "-10%", "+2st", "-2st"]
    static let rateSuggestions  = ["", "x-slow", "slow", "medium", "fast", "x-fast", "0.8", "0.9", "1.1", "1.2"]
    static let volumeSuggestions = ["", "silent", "x-soft", "soft", "medium", "loud", "x-loud", "+6dB", "-6dB"]
}

enum EmotionPreset: String, CaseIterable, Codable, Identifiable {
    case enthusiastic
    case agreement
    case animation
    case amazement
    case laughter
    case whispers
    case excitedly
    case shouting
    case sarcastically
    case sighs
    case reluctantly
    case tired
    case bored
    case happy
    case sad

    var id: String { rawValue }
    var displayName: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .enthusiastic: "enthusiastic"
        case .agreement: "agreement"
        case .animation: "animation"
        case .amazement: "amazement"
        case .laughter: "laughter"
        case .whispers: "whispers"
        case .excitedly: "excitedly"
        case .shouting: "shouting"
        case .sarcastically: "sarcastically"
        case .sighs: "sighs"
        case .reluctantly: "reluctantly"
        case .tired: "tired"
        case .bored: "bored"
        case .happy: "happy"
        case .sad: "sad"
        }
    }
}
