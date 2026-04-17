import Foundation

struct NarrativeParagraph: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var speakerId: UUID
    var emotion: String
    var content: String
}
