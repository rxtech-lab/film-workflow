import SwiftUI
import SwiftData

@main
struct film_workflowApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            MusicProject.self,
            GeneratedMusic.self,
            NarrativeProject.self,
            GeneratedNarrative.self,
            RemotionProject.self,
            RemotionMessage.self,
            ImageGenProject.self,
            GeneratedImage.self,
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
        #if os(macOS)
        // Clean up any bun/node/remotion processes left behind by an unclean exit
        // of a previous app launch (Bun's Chromium grandchildren survive Process.terminate).
        ProcessTreeKiller.killOrphans(matching: FileStorage.remotionRoot.path)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
            #if os(macOS)
                .environment(RemotionChatController.shared)
            #endif
        }
        .modelContainer(sharedModelContainer)

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
