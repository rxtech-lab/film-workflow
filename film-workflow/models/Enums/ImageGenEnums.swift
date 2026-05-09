import Foundation
import SwiftUI

enum ImageProvider: String, CaseIterable, Codable, Identifiable {
    case google = "google"
    case openai = "openai"

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .google: return "Google"
        case .openai: return "OpenAI"
        }
    }
}

enum ImageAspectRatio: String, CaseIterable, Codable, Identifiable {
    case r1x1 = "1:1"
    case r1x4 = "1:4"
    case r1x8 = "1:8"
    case r2x3 = "2:3"
    case r3x2 = "3:2"
    case r3x4 = "3:4"
    case r4x1 = "4:1"
    case r4x3 = "4:3"
    case r4x5 = "4:5"
    case r5x4 = "5:4"
    case r8x1 = "8:1"
    case r9x16 = "9:16"
    case r16x9 = "16:9"
    case r21x9 = "21:9"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

enum ImageResolution: String, CaseIterable, Codable, Identifiable {
    case r512 = "512"
    case r1k = "1K"
    case r2k = "2K"
    case r4k = "4K"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

enum ImageSize: String, CaseIterable, Codable, Identifiable {
    case auto = "auto"
    case s1024x1024 = "1024x1024"
    case s1024x1536 = "1024x1536"
    case s1536x1024 = "1536x1024"
    case custom = "custom"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .custom: return "Custom"
        default: return rawValue
        }
    }

    /// The literal value to send to the API. `nil` for `.custom` — caller composes "WxH".
    var apiValue: String? {
        switch self {
        case .custom: return nil
        default: return rawValue
        }
    }
}

enum ImageQuality: String, CaseIterable, Codable, Identifiable {
    case auto
    case low
    case medium
    case high

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum ImageFormat: String, CaseIterable, Codable, Identifiable {
    case png
    case jpeg
    case webp

    var id: String { rawValue }
    var displayName: String { rawValue.uppercased() }

    var supportsCompression: Bool {
        switch self {
        case .jpeg, .webp: return true
        case .png: return false
        }
    }

    var supportsTransparent: Bool {
        switch self {
        case .png, .webp: return true
        case .jpeg: return false
        }
    }
}

enum ImageBackground: String, CaseIterable, Codable, Identifiable {
    case auto
    case opaque

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}
