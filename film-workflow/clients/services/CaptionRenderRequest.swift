import Foundation
import VideoEditorCore

/// The caption choices that go with a sequence render: which language burns
/// in, which languages become subtitle tracks or files, and the file type.
/// The delivery itself is `TimelineExporter.Options.captions`; caption files
/// can also be written next to a burned-in or embedded render.
nonisolated struct CaptionRenderRequest: Codable, Equatable, Sendable {
    /// BCP-47 of the translation burned in; empty for the original.
    var burnInLanguage: String = ""
    /// Burn the original above `burnInLanguage` rather than instead of it.
    var burnInBilingual: Bool = false
    /// Languages for embedded tracks and sidecar files, one each. Empty
    /// string is the original.
    var trackLanguages: [String] = [""]
    /// Sidecar file type; only SubRip and WebVTT are offered.
    var sidecarFormat: CaptionExportFormat = .srt
    /// Write caption files beside the movie whatever the delivery, e.g. a
    /// burned-in render that also ships its translations as .srt files.
    var savesFiles: Bool = false
    /// Languages for `savesFiles`, one file each. Empty string is the original.
    var fileLanguages: [String] = [""]

    init(burnInLanguage: String = "", burnInBilingual: Bool = false, trackLanguages: [String] = [""], sidecarFormat: CaptionExportFormat = .srt,
         savesFiles: Bool = false, fileLanguages: [String] = [""]) {
        self.burnInLanguage = burnInLanguage
        self.burnInBilingual = burnInBilingual
        self.trackLanguages = trackLanguages
        self.sidecarFormat = sidecarFormat
        self.savesFiles = savesFiles
        self.fileLanguages = fileLanguages
    }

    private enum CodingKeys: String, CodingKey {
        case burnInLanguage, burnInBilingual, trackLanguages, sidecarFormat, savesFiles, fileLanguages
    }

    /// Requests saved before a field existed decode with its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        burnInLanguage = try c.decodeIfPresent(String.self, forKey: .burnInLanguage) ?? ""
        burnInBilingual = try c.decodeIfPresent(Bool.self, forKey: .burnInBilingual) ?? false
        trackLanguages = try c.decodeIfPresent([String].self, forKey: .trackLanguages) ?? [""]
        sidecarFormat = try c.decodeIfPresent(CaptionExportFormat.self, forKey: .sidecarFormat) ?? .srt
        savesFiles = try c.decodeIfPresent(Bool.self, forKey: .savesFiles) ?? false
        fileLanguages = try c.decodeIfPresent([String].self, forKey: .fileLanguages) ?? [""]
    }

    /// Whether a render with `delivery` writes caption files beside the movie.
    func writesFiles(for delivery: TimelineExporter.CaptionDelivery) -> Bool {
        delivery == .sidecar || savesFiles
    }

    /// The languages written as files: the track languages when files are the
    /// delivery itself, otherwise the separate-file choice.
    func fileLanguages(for delivery: TimelineExporter.CaptionDelivery) -> [String] {
        delivery == .sidecar ? trackLanguages : fileLanguages
    }

    /// What the burned-in caption clips show.
    var burnInSelection: CaptionTextSelection {
        if burnInLanguage.isEmpty { return .original }
        return burnInBilingual ? .bilingual(burnInLanguage) : .translation(burnInLanguage)
    }

    /// The same choice as a caption clip states it: the languages drawn on one
    /// caption, transcript first. `[""]` means "whatever each clip already
    /// says", since asking for the transcript is also the clip default.
    var burnInLanguages: [String] {
        if burnInLanguage.isEmpty { return [""] }
        return burnInBilingual ? ["", burnInLanguage] : [burnInLanguage]
    }

    /// The same request without languages the sequence cannot supply. Always
    /// keeps at least the original, so a render never ends up with no track.
    func narrowed(to available: [String]) -> CaptionRenderRequest {
        var copy = self
        if !available.contains(copy.burnInLanguage) { copy.burnInLanguage = "" }
        copy.trackLanguages = copy.trackLanguages.filter { available.contains($0) }
        if copy.trackLanguages.isEmpty { copy.trackLanguages = [""] }
        copy.fileLanguages = copy.fileLanguages.filter { available.contains($0) }
        if copy.fileLanguages.isEmpty { copy.fileLanguages = [""] }
        if !copy.sidecarFormat.isSidecar { copy.sidecarFormat = .srt }
        return copy
    }
}

extension CaptionExportFormat {
    /// Formats a player can load next to a movie.
    var isSidecar: Bool { self == .srt || self == .vtt }
    static var sidecarChoices: [CaptionExportFormat] { [.srt, .vtt] }
}
