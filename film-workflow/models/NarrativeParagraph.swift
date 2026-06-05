import Foundation

nonisolated struct NarrativeParagraph: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var speakerId: UUID
    var emotion: String
    var content: String
}
