import SwiftUI

/// The SF Symbols a category may wear.
///
/// macOS ships no symbol picker of its own, and the full set is far too large
/// to browse, so this is a hand-picked shortlist for a film marketplace. Every
/// name is checked against the running macOS, because the list outlives any one
/// release and a symbol that cannot be drawn must never be offered.
@MainActor
enum MarketplaceSymbolCatalog {
    /// What the backend falls back to, and what "no icon" draws as.
    static let fallback = "folder"

    static let all: [String] = candidates.filter(MarketplaceSymbol.exists)

    private static let candidates = [
        // The kinds themselves, so a category can echo its shelf.
        "film", "film.stack", "text.quote", "music.note", "music.note.list", "waveform",
        "textformat", "arrow.left.arrow.right.square", "wand.and.stars", "rectangle.stack.badge.play",
        // Shelves
        "folder", "tray", "square.grid.2x2", "square.stack", "sparkles", "star", "heart", "flame",
        "bolt", "crown", "tag", "bookmark", "flag", "pin",
        // Picture and camera
        "camera", "video", "photo", "photo.stack", "eye", "light.max", "circle.lefthalf.filled",
        "camera.aperture", "timelapse", "slowmo", "livephoto",
        // Sound
        "speaker.wave.2", "mic", "music.mic", "headphones", "metronome", "pianokeys", "guitars",
        // Places and moods
        "globe", "map", "building.2", "house", "mountain.2", "tree", "leaf", "drop", "snowflake",
        "sun.max", "moon.stars", "cloud", "wind", "water.waves", "beach.umbrella",
        // People and story
        "person", "person.2", "figure.walk", "figure.run", "hand.wave", "theatermasks", "book",
        // Motion and craft
        "car", "airplane", "bicycle", "sailboat", "paintbrush", "paintpalette", "scissors",
        "slider.horizontal.3", "dial.medium", "gauge.with.dots.needle.67percent",
        // Work and play
        "briefcase", "cart", "creditcard", "chart.line.uptrend.xyaxis", "graduationcap",
        "gamecontroller", "trophy", "fork.knife", "cup.and.saucer", "pawprint", "gift",
        "clock", "calendar", "bell", "lightbulb", "puzzlepiece", "cube", "atom",
    ]
}

/// Picks the SF Symbol a category shows in the sidebar.
///
/// The shortlist is a convenience, not the rule: the backend takes any symbol
/// name, so the field stays typable for one that is not listed here.
struct MarketplaceSymbolPicker: View {
    @Binding var symbol: String
    @State private var browsing = false
    @State private var search = ""

    private var trimmed: String { symbol.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// What the row draws: the chosen symbol, or the default it will get.
    private var preview: String { MarketplaceSymbol.resolve(symbol, fallback: MarketplaceSymbolCatalog.fallback) }
    private var matches: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return MarketplaceSymbolCatalog.all }
        return MarketplaceSymbolCatalog.all.filter { $0.contains(query) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { browsing = true } label: {
                Image(systemName: preview)
                    .frame(width: 18, height: 18)
                    .accessibilityLabel("Choose an icon")
            }
            .buttonStyle(.bordered)
            .help("Choose an SF Symbol for the sidebar row")
            .popover(isPresented: $browsing, arrowEdge: .bottom) { browser }
            .accessibilityIdentifier("marketplace-symbol-picker")
            TextField("Icon", text: $symbol)
                .help("SF Symbol for the sidebar row, e.g. music.note. Blank uses a folder.")
        }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search symbols", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], spacing: 6) {
                    ForEach(matches, id: \.self) { name in
                        Button {
                            symbol = name
                            browsing = false
                        } label: {
                            Image(systemName: name)
                                .frame(width: 26, height: 26)
                                .background(name == trimmed ? Color.accentColor.opacity(0.25) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
            }
            .frame(height: 220)
            if matches.isEmpty {
                Text("No symbol matches that. Type a name in the field instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Button("Use the Default Folder") {
                symbol = ""
                browsing = false
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
    }
}
