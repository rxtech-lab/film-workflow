import SwiftData
import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tabs = .Music

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(Tabs.Music.displayName, systemImage: Tabs.Music.systemImage, value: Tabs.Music) {
                MusicTabView()
            }
            Tab(Tabs.Narrative.displayName, systemImage: Tabs.Narrative.systemImage, value: Tabs.Narrative) {
                NarrativeTabView()
            }
            Tab(Tabs.ImageGen.displayName, systemImage: Tabs.ImageGen.systemImage, value: Tabs.ImageGen) {
                ImageGenTabView()
            }
            #if os(macOS)
            Tab(Tabs.Remotion.displayName, systemImage: Tabs.Remotion.systemImage, value: Tabs.Remotion) {
                RemotionTabView()
            }
            #endif
            #if !os(macOS)
            Tab(Tabs.Settings.displayName, systemImage: Tabs.Settings.systemImage, value: Tabs.Settings) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                }
            }
            #endif
        }
        .dismissKeyboardOnTapAndScroll()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [MusicProject.self, GeneratedMusic.self, NarrativeProject.self, GeneratedNarrative.self, RemotionProject.self, RemotionMessage.self, ImageGenProject.self, GeneratedImage.self], inMemory: true)
}
