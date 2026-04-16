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
                Text("Coming soon")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #if !os(macOS)
            Tab(Tabs.Settings.displayName, systemImage: Tabs.Settings.systemImage, value: Tabs.Settings) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                }
            }
            #endif
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [MusicProject.self, GeneratedMusic.self], inMemory: true)
}
