import Foundation
import SwiftUI

enum MusicGenre: String, CaseIterable, Codable, Identifiable {
    case pop = "Pop"
    case rock = "Rock"
    case jazz = "Jazz"
    case classical = "Classical"
    case electronic = "Electronic"
    case hiphop = "Hip Hop"
    case rnb = "R&B"
    case country = "Country"
    case folk = "Folk"
    case ambient = "Ambient"
    case cinematic = "Cinematic Orchestral"
    case lofi = "Lo-fi Hip Hop"
    case jazzFusion = "Jazz Fusion"
    case metal = "Metal"
    case blues = "Blues"
    case reggae = "Reggae"
    case latin = "Latin"
    case soul = "Soul"

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .pop: "Pop"
        case .rock: "Rock"
        case .jazz: "Jazz"
        case .classical: "Classical"
        case .electronic: "Electronic"
        case .hiphop: "Hip Hop"
        case .rnb: "R&B"
        case .country: "Country"
        case .folk: "Folk"
        case .ambient: "Ambient"
        case .cinematic: "Cinematic Orchestral"
        case .lofi: "Lo-fi Hip Hop"
        case .jazzFusion: "Jazz Fusion"
        case .metal: "Metal"
        case .blues: "Blues"
        case .reggae: "Reggae"
        case .latin: "Latin"
        case .soul: "Soul"
        }
    }
}

enum MusicInstrument: String, CaseIterable, Codable, Identifiable {
    case piano = "Piano"
    case acousticGuitar = "Acoustic Guitar"
    case electricGuitar = "Electric Guitar"
    case slideGuitar = "Slide Guitar"
    case bass = "Bass"
    case drums = "Drums"
    case strings = "Strings"
    case synth = "Synthesizer"
    case brass = "Brass"
    case woodwinds = "Woodwinds"
    case vocals = "Vocals"
    case percussion = "Percussion"
    case fenderRhodes = "Fender Rhodes Piano"
    case tr808 = "TR-808 Drum Machine"
    case violin = "Violin"
    case cello = "Cello"
    case flute = "Flute"
    case saxophone = "Saxophone"
    case trumpet = "Trumpet"
    case organ = "Organ"

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .piano: "Piano"
        case .acousticGuitar: "Acoustic Guitar"
        case .electricGuitar: "Electric Guitar"
        case .slideGuitar: "Slide Guitar"
        case .bass: "Bass"
        case .drums: "Drums"
        case .strings: "Strings"
        case .synth: "Synthesizer"
        case .brass: "Brass"
        case .woodwinds: "Woodwinds"
        case .vocals: "Vocals"
        case .percussion: "Percussion"
        case .fenderRhodes: "Fender Rhodes Piano"
        case .tr808: "TR-808 Drum Machine"
        case .violin: "Violin"
        case .cello: "Cello"
        case .flute: "Flute"
        case .saxophone: "Saxophone"
        case .trumpet: "Trumpet"
        case .organ: "Organ"
        }
    }
}

enum BPMPreset: Int, CaseIterable, Codable, Identifiable {
    case bpm60 = 60
    case bpm70 = 70
    case bpm80 = 80
    case bpm90 = 90
    case bpm100 = 100
    case bpm110 = 110
    case bpm120 = 120
    case bpm130 = 130
    case bpm140 = 140
    case bpm150 = 150
    case bpm160 = 160
    case bpm170 = 170
    case bpm180 = 180

    var id: Int { rawValue }
    var displayName: String { "\(rawValue) BPM" }
}

enum KeyScale: String, CaseIterable, Codable, Identifiable {
    case cMajor = "C Major"
    case cMinor = "C Minor"
    case dMajor = "D Major"
    case dMinor = "D Minor"
    case eMajor = "E Major"
    case eMinor = "E Minor"
    case fMajor = "F Major"
    case fMinor = "F Minor"
    case gMajor = "G Major"
    case gMinor = "G Minor"
    case aMajor = "A Major"
    case aMinor = "A Minor"
    case bFlatMajor = "Bb Major"
    case bFlatMinor = "Bb Minor"
    case bMajor = "B Major"
    case bMinor = "B Minor"

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .cMajor: "C Major"
        case .cMinor: "C Minor"
        case .dMajor: "D Major"
        case .dMinor: "D Minor"
        case .eMajor: "E Major"
        case .eMinor: "E Minor"
        case .fMajor: "F Major"
        case .fMinor: "F Minor"
        case .gMajor: "G Major"
        case .gMinor: "G Minor"
        case .aMajor: "A Major"
        case .aMinor: "A Minor"
        case .bFlatMajor: "Bb Major"
        case .bFlatMinor: "Bb Minor"
        case .bMajor: "B Major"
        case .bMinor: "B Minor"
        }
    }
}

enum Mood: String, CaseIterable, Codable, Identifiable {
    case happy = "Happy"
    case sad = "Sad"
    case energetic = "Energetic"
    case calm = "Calm"
    case dark = "Dark"
    case uplifting = "Uplifting"
    case mysterious = "Mysterious"
    case romantic = "Romantic"
    case aggressive = "Aggressive"
    case dreamy = "Dreamy"
    case nostalgic = "Nostalgic"
    case ethereal = "Ethereal"
    case epic = "Epic"
    case melancholic = "Melancholic"
    case playful = "Playful"

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .happy: "Happy"
        case .sad: "Sad"
        case .energetic: "Energetic"
        case .calm: "Calm"
        case .dark: "Dark"
        case .uplifting: "Uplifting"
        case .mysterious: "Mysterious"
        case .romantic: "Romantic"
        case .aggressive: "Aggressive"
        case .dreamy: "Dreamy"
        case .nostalgic: "Nostalgic"
        case .ethereal: "Ethereal"
        case .epic: "Epic"
        case .melancholic: "Melancholic"
        case .playful: "Playful"
        }
    }
}

enum MusicLength: String, CaseIterable, Codable, Identifiable {
    case sec30 = "0:30"
    case min1 = "1:00"
    case min1_30 = "1:30"
    case min2 = "2:00"
    case min2_30 = "2:30"
    case min3 = "3:00"

    var id: String { rawValue }

    var seconds: Int {
        switch self {
        case .sec30: return 30
        case .min1: return 60
        case .min1_30: return 90
        case .min2: return 120
        case .min2_30: return 150
        case .min3: return 180
        }
    }

    var promptDescription: String {
        switch self {
        case .sec30: return "30-second"
        case .min1: return "1-minute"
        case .min1_30: return "1 minute 30 second"
        case .min2: return "2-minute"
        case .min2_30: return "2 minute 30 second"
        case .min3: return "3-minute"
        }
    }
}

enum InputMode: String, CaseIterable, Codable, Identifiable {
    case prompt = "Prompt"
    case editor = "Editor"

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .prompt: "Prompt"
        case .editor: "Editor"
        }
    }
}

enum AudioFormat: String, CaseIterable, Codable, Identifiable {
    case mp3 = "audio/mp3"
    case wav = "audio/wav"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mp3: return "MP3"
        case .wav: return "WAV"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp3: return "mp3"
        case .wav: return "wav"
        }
    }

    var requestMimeType: String? {
        switch self {
        case .mp3: return nil
        case .wav: return "audio/wav"
        }
    }
}

enum GenerationType: String, CaseIterable, Codable, Identifiable {
    case withLyrics = "With Lyrics"
    case withoutLyrics = "Instrumental"

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .withLyrics: "With Lyrics"
        case .withoutLyrics: "Instrumental"
        }
    }
}

enum SongSectionType: String, CaseIterable, Codable, Identifiable {
    case intro = "Intro"
    case verse = "Verse"
    case chorus = "Chorus"
    case bridge = "Bridge"
    case outro = "Outro"
    case build = "Build"

    var id: String { rawValue }
    var tag: String { "[\(rawValue)]" }

    var localizedName: LocalizedStringKey {
        switch self {
        case .intro: "Intro"
        case .verse: "Verse"
        case .chorus: "Chorus"
        case .bridge: "Bridge"
        case .outro: "Outro"
        case .build: "Build"
        }
    }
}

enum LyricsLanguage: String, CaseIterable, Codable, Identifiable {
    case english = "English"
    case spanish = "Spanish"
    case french = "French"
    case german = "German"
    case italian = "Italian"
    case portuguese = "Portuguese"
    case japanese = "Japanese"
    case korean = "Korean"
    case chinese = "Chinese"
    case arabic = "Arabic"
    case hindi = "Hindi"
    case russian = "Russian"
    case turkish = "Turkish"
    case thai = "Thai"
    case vietnamese = "Vietnamese"

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .english: "English"
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .italian: "Italian"
        case .portuguese: "Portuguese"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .chinese: "Chinese"
        case .arabic: "Arabic"
        case .hindi: "Hindi"
        case .russian: "Russian"
        case .turkish: "Turkish"
        case .thai: "Thai"
        case .vietnamese: "Vietnamese"
        }
    }
}
