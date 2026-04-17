import Foundation

struct PromptBuilder {
    static func build(from project: MusicProject) -> String {
        var lines: [String] = []

        let trimmedVibe = project.generalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVibe.isEmpty {
            lines.append("Overall vibe: \(trimmedVibe)")
            lines.append("")
        }

        // Generation type and genre
        let genType = project.generationTypeEnum
        let genre = project.genreEnum
        if genType == .withoutLyrics {
            lines.append("Create a \(project.musicLengthEnum.promptDescription) instrumental \(genre.rawValue) track.")
            lines.append("Instrumental only, no vocals.")
        } else {
            lines.append("Create a \(project.musicLengthEnum.promptDescription) \(genre.rawValue) song with vocals and lyrics.")
            lines.append("Lyrics language: \(project.lyricsLanguageEnum.rawValue).")
        }

        // Musical parameters
        lines.append("")
        lines.append("Mood: \(project.moodEnum.rawValue).")
        lines.append("BPM: \(project.bpm).")
        lines.append("Key: \(project.keyScaleEnum.rawValue).")

        if !project.instruments.isEmpty {
            lines.append("Instruments: \(project.instruments.joined(separator: ", ")).")
        }

        // Song structure
        if !project.songStructureEntries.isEmpty {
            lines.append("")
            lines.append("Song structure:")
            for entry in project.songStructureEntries.sorted(by: { $0.startTime < $1.startTime }) {
                var line = "\(entry.formattedTimeRange) \(entry.type.tag)"
                line += " (intensity: \(entry.intensityLabel))"
                if !entry.description.isEmpty {
                    line += " \(entry.description)"
                }
                lines.append(line)
            }
        }

        // Lyrics
        if genType == .withLyrics && !project.lyricEntries.isEmpty {
            lines.append("")
            lines.append("Lyrics:")
            for entry in project.lyricEntries.sorted(by: { $0.timestamp < $1.timestamp }) {
                lines.append("[\(entry.formattedTimestamp)]")
                lines.append(entry.content)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }
}
