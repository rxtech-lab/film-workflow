import Foundation
import SwiftData

/// The app-wide store for data that is not part of any one film: agent
/// threads and their messages. Lives in Application Support as `Agent.store`.
@MainActor
enum AppModelContainer {
    static let schema = Schema([
        AgentThread.self,
        AgentMessage.self,
    ])

    static let shared: ModelContainer = {
        let configuration = ModelConfiguration(schema: schema, url: FileStorage.agentStoreURL)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create the app model container: \(error)")
        }
    }()
}
