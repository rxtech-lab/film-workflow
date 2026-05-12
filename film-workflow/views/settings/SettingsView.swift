import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AIProviderSettingsView()
                .tabItem {
                    Label("AI Provider", systemImage: "sparkles")
                }

            MCPSettingsView()
                .tabItem {
                    Label("MCP Server", systemImage: "network")
                }
        }
        #if os(macOS)
        .frame(width: 560, height: 600)
        #endif
    }
}
