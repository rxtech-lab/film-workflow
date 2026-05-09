import SwiftUI

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case aiProvider = "AI Provider"
        var id: String { rawValue }
        var displayName: LocalizedStringKey { LocalizedStringKey(rawValue) }
        var systemImage: String {
            switch self {
            case .aiProvider: return "sparkles"
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(width: 560, height: 520)
        #endif
    }
}
