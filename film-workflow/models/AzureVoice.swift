import Foundation

struct AzureVoice: Codable, Hashable, Identifiable {
    let shortName: String
    let localName: String
    let locale: String
    let localeName: String?
    let gender: String
    let voiceType: String
    let styleList: [String]

    var id: String { shortName }

    var localeDisplayName: String { localeName ?? locale }

    var languageCode: String {
        if let first = locale.split(separator: "-").first { return String(first).lowercased() }
        return locale.lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case shortName = "ShortName"
        case localName = "LocalName"
        case locale = "Locale"
        case localeName = "LocaleName"
        case gender = "Gender"
        case voiceType = "VoiceType"
        case styleList = "StyleList"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shortName = try c.decode(String.self, forKey: .shortName)
        localName = try c.decodeIfPresent(String.self, forKey: .localName) ?? shortName
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? ""
        localeName = try c.decodeIfPresent(String.self, forKey: .localeName)
        gender = try c.decodeIfPresent(String.self, forKey: .gender) ?? ""
        voiceType = try c.decodeIfPresent(String.self, forKey: .voiceType) ?? ""
        styleList = try c.decodeIfPresent([String].self, forKey: .styleList) ?? []
    }
}
