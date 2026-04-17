import Foundation

struct NarrativeSpeaker: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var displayName: String
    var voice: String
    var geminiVoice: String = ""
    var azureVoice: String = ""

    var azurePitch: String = ""
    var azureRate: String = ""
    var azureVolume: String = ""
    var azureRole: String = ""
    var azureStyleDegree: Double = 1.0

    var voiceEnum: GeminiVoice {
        get { GeminiVoice(rawValue: voice) ?? .achernar }
        set { voice = newValue.rawValue }
    }

    var azureRoleEnum: AzureRole {
        get { AzureRole(rawValue: azureRole) ?? .none }
        set { azureRole = newValue.rawValue }
    }

    var hasAzureProsody: Bool {
        !azurePitch.isEmpty || !azureRate.isEmpty || !azureVolume.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, voice, geminiVoice, azureVoice
        case azurePitch, azureRate, azureVolume, azureRole, azureStyleDegree
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        voice: String,
        geminiVoice: String = "",
        azureVoice: String = "",
        azurePitch: String = "",
        azureRate: String = "",
        azureVolume: String = "",
        azureRole: String = "",
        azureStyleDegree: Double = 1.0
    ) {
        self.id = id
        self.displayName = displayName
        self.voice = voice
        self.geminiVoice = geminiVoice
        self.azureVoice = azureVoice
        self.azurePitch = azurePitch
        self.azureRate = azureRate
        self.azureVolume = azureVolume
        self.azureRole = azureRole
        self.azureStyleDegree = azureStyleDegree
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        self.voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        self.geminiVoice = try c.decodeIfPresent(String.self, forKey: .geminiVoice) ?? ""
        self.azureVoice = try c.decodeIfPresent(String.self, forKey: .azureVoice) ?? ""
        self.azurePitch = try c.decodeIfPresent(String.self, forKey: .azurePitch) ?? ""
        self.azureRate = try c.decodeIfPresent(String.self, forKey: .azureRate) ?? ""
        self.azureVolume = try c.decodeIfPresent(String.self, forKey: .azureVolume) ?? ""
        self.azureRole = try c.decodeIfPresent(String.self, forKey: .azureRole) ?? ""
        self.azureStyleDegree = try c.decodeIfPresent(Double.self, forKey: .azureStyleDegree) ?? 1.0
    }
}
