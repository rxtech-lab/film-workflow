import SwiftUI
import SwiftData

@main
struct film_workflowApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            MusicProject.self,
            GeneratedMusic.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        FileStorage.ensureDirectories()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)

        Settings {
            SettingsView()
        }
    }
}
