import Foundation
import SwiftUI

/// Video-generation backends.
///
/// Only Google is wired today. The enum exists (rather than the project simply
/// assuming Veo) because an OpenAI-compatible `/v1/videos` provider is the
/// planned second case, and the per-provider column prefixes on
/// `VideoGenProject` let it land without a schema migration. See
/// `docs/video-generation.md` for why Vercel AI Gateway is not one of these.
enum VideoProvider: String, CaseIterable, Codable, Identifiable {
    case google = "google"

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .google: return "Google"
        }
    }
}

enum VideoAspectRatio: String, CaseIterable, Codable, Identifiable {
    case r16x9 = "16:9"
    case r9x16 = "9:16"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

enum VideoResolution: String, CaseIterable, Codable, Identifiable {
    case r360p = "360p"
    case r720p = "720p"
    case r1080p = "1080p"
    case r4k = "4k"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .r4k: return "4K"
        default: return rawValue
        }
    }

    /// Veo renders 1080p and 4k as 8-second clips only.
    var requiresEightSeconds: Bool { self != .r720p }
}

enum VideoDuration: String, CaseIterable, Codable, Identifiable {
    case s3 = "3"
    case s4 = "4"
    case s5 = "5"
    case s6 = "6"
    case s7 = "7"
    case s8 = "8"
    case s9 = "9"
    case s10 = "10"
    case s11 = "11"
    case s12 = "12"
    case s13 = "13"
    case s14 = "14"
    case s15 = "15"

    var id: String { rawValue }
    var displayName: String { "\(rawValue)s" }
    var seconds: Int { Int(rawValue) ?? 8 }
}

enum VideoPersonGeneration: String, CaseIterable, Codable, Identifiable {
    case allowAll = "allow_all"
    case allowAdult = "allow_adult"
    case dontAllow = "dont_allow"

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .allowAll: return "Allow all"
        case .allowAdult: return "Adults only"
        case .dontAllow: return "Don't allow people"
        }
    }
}

/// What the selected Veo model can actually do.
///
/// Derived from the model id rather than a hardcoded allowlist: Google renames
/// these regularly (`veo-3.1-generate-preview` → `veo-3.1-generate-001` → …),
/// so the picker is fed from the live model list and this only *classifies*
/// whatever came back. An id we don't recognise falls through to `.unknown`,
/// which offers the conservative common denominator rather than nothing.
enum VeoModelFamily {
    case omni12
    case omni11
    case veo2
    case veo3
    case veo31
    case veo31Fast
    case veo31Lite
    case unknown

    static func from(_ id: String) -> VeoModelFamily {
        let name = id.lowercased()
        if name == "gemini-omni-1.2-flash" { return .omni12 }
        if name == "gemini-omni-1.1-flash" { return .omni11 }
        if name.contains("veo-3.1") || name.contains("veo-31") {
            if name.contains("lite") { return .veo31Lite }
            if name.contains("fast") { return .veo31Fast }
            return .veo31
        }
        if name.contains("veo-3") { return .veo3 }
        if name.contains("veo-2") { return .veo2 }
        return .unknown
    }

    var resolutions: [VideoResolution] {
        switch self {
        case .omni12, .omni11: return [.r360p, .r720p, .r1080p, .r4k]
        case .veo2: return [.r720p]
        case .veo3, .veo31Lite: return [.r720p, .r1080p]
        case .veo31, .veo31Fast: return [.r720p, .r1080p, .r4k]
        case .unknown: return [.r720p, .r1080p]
        }
    }

    /// Durations before the resolution / reference-image constraints narrow them.
    var baseDurations: [VideoDuration] {
        switch self {
        case .omni12: return VideoDuration.allCases.sorted { $0.seconds < $1.seconds }
        case .omni11: return VideoDuration.allCases.filter { $0.seconds <= 10 }.sorted { $0.seconds < $1.seconds }
        case .veo2: return [.s5, .s6, .s8]
        default: return [.s4, .s6, .s8]
        }
    }

    var maxVideos: Int { self == .veo2 ? 2 : 1 }

    /// Veo 3 onwards returns exactly one clip and rejects the parameter
    /// outright — it can't be sent even as `1`.
    var supportsNumberOfVideos: Bool { maxVideos > 1 }

    var isOmni: Bool { self == .omni12 || self == .omni11 }
    var maxReferenceImages: Int { isOmni ? 6 : 3 }
    var supportsSeed: Bool { !isOmni && self != .veo2 }

    /// Native audio arrived with Veo 3, but only as a *switchable* parameter:
    /// Veo 2 has no audio at all and 3.1 Lite rejects the key outright (it
    /// decides for itself), so neither can be sent one.
    var supportsAudio: Bool { !isOmni && self != .veo2 && self != .veo31Lite }

    var supportsReferenceImages: Bool { isOmni || self == .veo31 || self == .veo31Fast }

    /// 1080p/4k and reference images both force an 8-second clip.
    func durations(resolution: VideoResolution, usingReferenceImages: Bool, interpolating: Bool = false) -> [VideoDuration] {
        if isOmni { return baseDurations.filter { !interpolating || $0.seconds <= 10 } }
        if resolution.requiresEightSeconds || usingReferenceImages { return [.s8] }
        return baseDurations
    }
}

extension VeoModelFamily {
    /// Forces the project's parameters back into a combination this family
    /// accepts. Called whenever the model or resolution changes so an illegal
    /// pairing can never be persisted — the API rejects them, and a stale
    /// selection is otherwise invisible until Generate fails.
    static func clamp(_ project: VideoGenProject) {
        let family = VeoModelFamily.from(project.googleModel)

        var resolution = project.googleResolutionEnum
        if !family.resolutions.contains(resolution) {
            resolution = family.resolutions.last ?? .r720p
            project.googleResolution = resolution.rawValue
        }

        let allowed = family.durations(
            resolution: resolution,
            usingReferenceImages: !project.googleReferenceImagePaths.isEmpty,
            interpolating: project.googleFirstFrameImagePath != nil && project.googleLastFrameImagePath != nil
        )
        if !allowed.contains(project.googleDurationEnum) {
            project.googleDuration = (allowed.first ?? .s8).rawValue
        }

        if project.googleNumberOfVideos > family.maxVideos {
            project.googleNumberOfVideos = family.maxVideos
        }
        if project.googleReferenceImagePaths.count > family.maxReferenceImages {
            project.googleReferenceImagePaths = Array(project.googleReferenceImagePaths.prefix(family.maxReferenceImages))
        }
        if !family.supportsSeed {
            project.useSeed = false
        }
        if !family.supportsAudio {
            project.googleGenerateAudio = false
        }
        if !family.supportsReferenceImages, !project.googleReferenceImagePaths.isEmpty {
            project.googleReferenceImagePaths = []
        }
    }
}
