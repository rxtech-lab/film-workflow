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
            CaptionProject.self,
            CaptionSegment.self,
            CaptionAssistantMessage.self,
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
        // Audio chunks and multipart bodies staged during transcription can be
        // hundreds of megabytes; a crash mid-run would otherwise leak them.
        FileStorage.clearTemp()
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
                .environment(CaptionAssistantController.shared)
                .task {
                    MCPServer.shared.bootstrap(container: sharedModelContainer)
                }
        }
        .modelContainer(sharedModelContainer)

        #if os(macOS)
        // The caption assistant gets its own window rather than a pane: editing
        // captions means watching the list change as edits land, and a sheet or
        // inspector would cover the thing you're editing. Keyed by
        // `CaptionProject.projectUUID` so each project opens its own window and
        // re-opening focuses the existing one.
        WindowGroup(id: CaptionAssistantWindowID.value, for: UUID.self) { $projectUUID in
            CaptionAssistantWindow(projectUUID: projectUUID)
                .environment(CaptionAssistantController.shared)
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 420, height: 640)

        Settings {
            SettingsView()
        }
        #endif
    }
}
