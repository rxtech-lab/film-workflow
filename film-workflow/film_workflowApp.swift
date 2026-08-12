import SwiftData
import SwiftUI

@main
struct film_workflowApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            MusicProject.self,
            GeneratedMusic.self,
            NarrativeProject.self,
            GeneratedNarrative.self,
            RemotionProject.self,
            ImageGenProject.self,
            GeneratedImage.self,
            CaptionProject.self,
            CaptionSegment.self,
            ProjectGroup.self,
            AgentThread.self,
            AgentMessage.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

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
                .environment(AgentController.shared)
                .task {
                    MCPServer.shared.bootstrap(container: sharedModelContainer)
                }
        }
        .modelContainer(sharedModelContainer)
        #if os(macOS)
            .commands {
                CommandGroup(after: .toolbar) {
                    Button("Agent") {
                        openWindow(id: AgentWindowID.value)
                    }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                }
            }
        #endif

        #if os(macOS)
        // One agent window for the whole app — a `Window` rather than a
        // `WindowGroup` because there is exactly one of it, so reopening raises
        // the existing window instead of minting another. It carries no scene
        // payload: what the agent is working on lives on the thread, not on the
        // window, which is what lets several threads target different projects
        // at once.
        Window("Agent", id: AgentWindowID.value) {
            AgentWindowView()
                .environment(AgentController.shared)
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 760, height: 720)

        Settings {
            SettingsView()
        }
        #endif
    }
}
