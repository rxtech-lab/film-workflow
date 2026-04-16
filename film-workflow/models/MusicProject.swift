import Foundation
import SwiftData

@Model
final class MusicProject {
    var name: String
    var createdAt: Date
    var updatedAt: Date

    var inputMode: String
    var promptText: String

    var genre: String
    var instruments: [String]
    var bpm: Int
    var keyScale: String
    var mood: String
    var musicLength: String
    var generationType: String
    var lyricsLanguage: String

    var songStructureEntries: [SongStructureEntry]
    var lyricEntries: [LyricEntry]
    var referenceImagePaths: [String]

    @Relationship(deleteRule: .cascade, inverse: \GeneratedMusic.project)
    var generatedFiles: [GeneratedMusic]

    init(name: String) {
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.inputMode = InputMode.editor.rawValue
        self.promptText = ""
        self.genre = MusicGenre.cinematic.rawValue
        self.instruments = []
        self.bpm = 120
        self.keyScale = KeyScale.cMajor.rawValue
        self.mood = Mood.calm.rawValue
        self.musicLength = MusicLength.min1.rawValue
        self.generationType = GenerationType.withLyrics.rawValue
        self.lyricsLanguage = LyricsLanguage.english.rawValue
        self.songStructureEntries = []
        self.lyricEntries = []
        self.referenceImagePaths = []
        self.generatedFiles = []
    }

    // MARK: - Computed enum accessors

    var inputModeEnum: InputMode {
        get { InputMode(rawValue: inputMode) ?? .editor }
        set { inputMode = newValue.rawValue }
    }

    var genreEnum: MusicGenre {
        get { MusicGenre(rawValue: genre) ?? .cinematic }
        set { genre = newValue.rawValue }
    }

    var instrumentEnums: Set<MusicInstrument> {
        get { Set(instruments.compactMap { MusicInstrument(rawValue: $0) }) }
        set { instruments = newValue.map(\.rawValue).sorted() }
    }

    var bpmPreset: BPMPreset {
        get { BPMPreset(rawValue: bpm) ?? .bpm120 }
        set { bpm = newValue.rawValue }
    }

    var keyScaleEnum: KeyScale {
        get { KeyScale(rawValue: keyScale) ?? .cMajor }
        set { keyScale = newValue.rawValue }
    }

    var moodEnum: Mood {
        get { Mood(rawValue: mood) ?? .calm }
        set { mood = newValue.rawValue }
    }

    var musicLengthEnum: MusicLength {
        get { MusicLength(rawValue: musicLength) ?? .min1 }
        set { musicLength = newValue.rawValue }
    }

    var generationTypeEnum: GenerationType {
        get { GenerationType(rawValue: generationType) ?? .withLyrics }
        set { generationType = newValue.rawValue }
    }

    var lyricsLanguageEnum: LyricsLanguage {
        get { LyricsLanguage(rawValue: lyricsLanguage) ?? .english }
        set { lyricsLanguage = newValue.rawValue }
    }
}
