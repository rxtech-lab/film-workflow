import SwiftUI

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case aiProvider = "AI Provider"
        case mcpServer = "MCP Server"
        var id: String { rawValue }
        var displayName: LocalizedStringKey { LocalizedStringKey(rawValue) }
        var systemImage: String {
            switch self {
            case .aiProvider: return "sparkles"
            case .mcpServer: return "network"
            }
        }
    }

    @State private var selectedSection: Section = .aiProvider

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedSection) {
                ForEach(Section.allCases) { section in
                    Label(section.displayName, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch selectedSection {
                case .aiProvider:
                    AIProviderSettingsView()
                case .mcpServer:
                    MCPSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(width: 560, height: 600)
        #endif
    }
}
