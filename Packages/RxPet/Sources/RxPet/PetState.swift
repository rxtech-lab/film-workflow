import Foundation

public enum PetMood: String, Codable, CaseIterable, Sendable { case neutral, happy, focused, curious, sleepy, concerned }
public enum PetStatus: String, Codable, CaseIterable, Sendable { case idle, preparing, recording, replaying, waiting, paused, completed, failed }
public enum PetMotion: String, Codable, CaseIterable, Sendable {
    case automatic, idle, working, waiting, resting, waving, walking, celebration, failure
    public var atlasRow: Int { switch self { case .automatic, .idle: 0; case .working: 1; case .waiting: 2; case .resting: 3; case .waving: 4; case .walking: 5; case .celebration: 6; case .failure: 7 } }
}
public struct PetState: Codable, Equatable, Sendable {
    public var mood: PetMood?
    public var status: PetStatus
    public var motion: PetMotion
    public var message: String?
    public init(mood: PetMood? = nil, status: PetStatus = .idle, motion: PetMotion = .automatic, message: String? = nil) {
        self.mood = mood; self.status = status; self.motion = motion; self.message = message
    }
    public var resolvedMotion: PetMotion {
        guard motion == .automatic else { return motion }
        switch status { case .idle: return .idle; case .preparing: return .waving; case .recording, .replaying: return .working; case .waiting: return .waiting; case .paused: return .resting; case .completed: return .celebration; case .failed: return .failure }
    }
    public var resolvedMood: PetMood {
        if let mood { return mood }
        switch status { case .idle: return .neutral; case .preparing, .waiting: return .curious; case .recording, .replaying: return .focused; case .paused: return .sleepy; case .completed: return .happy; case .failed: return .concerned }
    }
}
public struct PetCharacter: Hashable, Sendable {
    public var atlasURL: URL
    public var expressionsURL: URL?
    public var manifestURL: URL?
    public var columns: Int
    public var rows: Int
    public var framesPerSecond: Double
    public init(atlasURL: URL, expressionsURL: URL? = nil, manifestURL: URL? = nil, columns: Int = 6, rows: Int = 8, framesPerSecond: Double = 4) {
        self.atlasURL = atlasURL; self.expressionsURL = expressionsURL; self.manifestURL = manifestURL; self.columns = max(1, columns); self.rows = max(1, rows); self.framesPerSecond = max(1, framesPerSecond)
    }
    public static var cameraBuddy: Self { .init(atlasURL: Bundle.module.url(forResource: "camera-atlas", withExtension: "webp")!, expressionsURL: Bundle.module.url(forResource: "camera-expressions", withExtension: "webp"), manifestURL: Bundle.module.url(forResource: "camera-animation", withExtension: "json")) }
}
