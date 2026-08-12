import SwiftUI

struct SettingsView: View {
    // Bound to the shared navigation so callers can deep-link a section.
    @State private var navigation = AppNavigation.shared

    var body: some View {
        TabView(selection: $navigation.settingsSection) {
            AIProviderSettingsView()
                .tabItem {
                    Label("AI Provider", systemImage: "sparkles")
                }
                .tag(AppNavigation.SettingsSection.aiProvider)

            AgentSettingsView()
                .tabItem {
                    Label("Agent", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(AppNavigation.SettingsSection.agent)

            CaptionSettingsView()
                .tabItem {
                    Label("Captions", systemImage: "captions.bubble")
                }
                .tag(AppNavigation.SettingsSection.captions)

            MCPSettingsView()
                .tabItem {
                    Label("MCP Server", systemImage: "network")
                }
                .tag(AppNavigation.SettingsSection.mcp)
        }
        #if os(macOS)
        // Taller than the other tabs need: the Whisper model list is long.
        .frame(width: 560, height: 660)
        #endif
    }
}
