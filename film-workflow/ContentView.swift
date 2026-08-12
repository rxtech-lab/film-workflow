import SwiftData
import SwiftUI

struct ContentView: View {
    // Shared rather than local @State so a deep-linked screen (e.g. "download a
    // Whisper model") can switch tabs.
    @State private var navigation = AppNavigation.shared

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
        .modelContainer(for: [MusicProject.self, GeneratedMusic.self, NarrativeProject.self, GeneratedNarrative.self, RemotionProject.self, RemotionMessage.self, ImageGenProject.self, GeneratedImage.self, CaptionProject.self, CaptionSegment.self], inMemory: true)
}
