import Foundation

/// The caption choices that go with a sequence render: which language burns
/// in, which languages become subtitle tracks or files, and the file type.
/// The delivery itself is `TimelineExporter.Options.captions`.
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

    init(burnInLanguage: String = "", burnInBilingual: Bool = false, trackLanguages: [String] = [""], sidecarFormat: CaptionExportFormat = .srt) {
        self.burnInLanguage = burnInLanguage
        self.burnInBilingual = burnInBilingual
        self.trackLanguages = trackLanguages
        self.sidecarFormat = sidecarFormat
    }

    private enum CodingKeys: String, CodingKey {
        case burnInLanguage, burnInBilingual, trackLanguages, sidecarFormat
    }

    /// Requests saved before a field existed decode with its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        burnInLanguage = try c.decodeIfPresent(String.self, forKey: .burnInLanguage) ?? ""
        burnInBilingual = try c.decodeIfPresent(Bool.self, forKey: .burnInBilingual) ?? false
        trackLanguages = try c.decodeIfPresent([String].self, forKey: .trackLanguages) ?? [""]
        sidecarFormat = try c.decodeIfPresent(CaptionExportFormat.self, forKey: .sidecarFormat) ?? .srt
    }

    /// What the burned-in caption clips show.
    var burnInSelection: CaptionTextSelection {
        if burnInLanguage.isEmpty { return .original }
        return burnInBilingual ? .bilingual(burnInLanguage) : .translation(burnInLanguage)
    }

    /// The same request without languages the sequence cannot supply. Always
    /// keeps at least the original, so a render never ends up with no track.
    func narrowed(to available: [String]) -> CaptionRenderRequest {
        var copy = self
        if !available.contains(copy.burnInLanguage) { copy.burnInLanguage = "" }
        copy.trackLanguages = copy.trackLanguages.filter { available.contains($0) }
        if copy.trackLanguages.isEmpty { copy.trackLanguages = [""] }
        if !copy.sidecarFormat.isSidecar { copy.sidecarFormat = .srt }
        return copy
    }
}

extension CaptionExportFormat {
    /// Formats a player can load next to a movie.
    var isSidecar: Bool { self == .srt || self == .vtt }
    static var sidecarChoices: [CaptionExportFormat] { [.srt, .vtt] }
}
