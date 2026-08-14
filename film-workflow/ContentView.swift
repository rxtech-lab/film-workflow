import SwiftData
import SwiftUI
import TipKit

struct ContentView: View {
    // Shared rather than local @State so a deep-linked screen (e.g. "download a
    // Whisper model") can switch tabs.
    @State private var navigation = AppNavigation.shared
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
        @State private var agentController = AgentController.shared
    #endif

    var body: some View {
        TabView(selection: $navigation.tab) {
            Tab(Tabs.Music.displayName, systemImage: Tabs.Music.systemImage, value: Tabs.Music) {
                MusicTabView()
            }
            Tab(Tabs.Narrative.displayName, systemImage: Tabs.Narrative.systemImage, value: Tabs.Narrative) {
                NarrativeTabView()
            }
            Tab(Tabs.Caption.displayName, systemImage: Tabs.Caption.systemImage, value: Tabs.Caption) {
                CaptionTabView()
            }
            Tab(Tabs.ImageGen.displayName, systemImage: Tabs.ImageGen.systemImage, value: Tabs.ImageGen) {
                ImageGenTabView()
            }
            Tab(Tabs.VideoGen.displayName, systemImage: Tabs.VideoGen.systemImage, value: Tabs.VideoGen) {
                VideoGenTabView()
            }
            #if os(macOS)
            Tab(Tabs.Remotion.displayName, systemImage: Tabs.Remotion.systemImage, value: Tabs.Remotion) {
                RemotionTabView()
            }
            #endif
            #if !os(macOS)
            // iOS has no second scene, so the agent is a tab here; on macOS it
            // is a window (see `film_workflowApp`).
            Tab(Tabs.Agent.displayName, systemImage: Tabs.Agent.systemImage, value: Tabs.Agent) {
                AgentWindowView()
            }
            Tab(Tabs.Settings.displayName, systemImage: Tabs.Settings.systemImage, value: Tabs.Settings) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                }
            }
            #endif
        }
        .dismissKeyboardOnTapAndScroll()
        .sheet(isPresented: $navigation.showAccountSheet) {
            AccountSheet()
        }
        .onOpenURL { AuthSessionBridge.handle($0) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await CreditBalanceStore.shared.refresh() }
        }
        #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openWindow(id: AgentWindowID.value)
                    } label: {
                        Label("Agent", systemImage: "sparkles")
                            .overlay(alignment: .topTrailing) {
                                if agentController.runningCount > 0 {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 6, height: 6)
                                        .offset(x: 3, y: -2)
                                }
                            }
                    }
                    .help(
                        agentController.runningCount > 0
                            ? "Open the agent (running)"
                            : "Open the agent"
                    )
                    .popoverTip(FilmWorkflowTips.AgentButtonTip(), arrowEdge: .top)
                }
            }
        #endif
    }
}

#Preview {
    ContentView()
        .environment(AgentController.shared)
        .modelContainer(for: [MusicProject.self, GeneratedMusic.self, NarrativeProject.self, GeneratedNarrative.self, RemotionProject.self, ImageGenProject.self, GeneratedImage.self, VideoGenProject.self, GeneratedVideo.self, CaptionProject.self, CaptionSegment.self, ProjectGroup.self, AgentThread.self, AgentMessage.self], inMemory: true)
}
