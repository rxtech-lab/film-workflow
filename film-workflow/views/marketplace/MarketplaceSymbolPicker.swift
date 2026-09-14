import AppKit
import SwiftUI

/// Every SF Symbol a category may wear.
///
/// AppKit exposes no way to enumerate the set, so the names are read from the
/// system's own symbol index. It is the *running* system's copy, so every name
/// in it is drawable here — no release can offer a symbol this Mac lacks — and
/// the order is Apple's own, which is how the symbols are grouped in their
/// tools. If a future macOS moves that index the shortlist below stands in,
/// checked symbol by symbol before it is offered.
@MainActor
enum MarketplaceSymbolCatalog {
    /// What the backend falls back to, and what "no icon" draws as.
    static let fallback = "folder"

    /// The full list, in Apple's order.
    static let all: [String] = systemIndex() ?? shortlist.filter(MarketplaceSymbol.exists)

    /// Extra words a symbol answers to, so "sound" finds `speaker.wave.2`.
    /// Absent from the index on a system that does not ship it; searching then
    /// falls back to the name alone.
    static let keywords: [String: [String]] = resource("symbol_search") ?? [:]

    private static let indexBundle = "/System/Library/CoreServices/CoreGlyphs.bundle"

    /// The trailing component of a localized or right-to-left variant. These
    /// draw the same idea for one script and would fill the grid with
    /// duplicates, so they are left to the system to substitute at draw time.
    private static let variantSuffixes: Set<String> = [
        "ar", "bn", "el", "gu", "he", "hi", "ja", "km", "kn", "ko", "ml", "mr",
        "my", "or", "pa", "ru", "si", "ta", "te", "th", "zh", "rtl", "ltr",
    ]

    private static func systemIndex() -> [String]? {
        guard let order: [String] = resource("symbol_order"), !order.isEmpty else { return nil }
        // Symbols Apple reserves for its own products ("may only be used to
        // refer to Apple's iPhone") have no business labelling a category.
        let restricted = Set((resource("symbol_restrictions") as [String: String]? ?? [:]).keys)
        return order.filter { name in
            !restricted.contains(name) && !variantSuffixes.contains(name.split(separator: ".").last.map(String.init) ?? "")
        }
    }

    private static func resource<Value>(_ name: String) -> Value? {
        guard let bundle = Bundle(path: indexBundle),
              let url = bundle.url(forResource: name, withExtension: "plist") ?? bundle.url(forResource: name, withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return value as? Value
    }

    /// The last resort: a hand-picked set for a film marketplace, used only
    /// when the system index cannot be read.
    private static let shortlist = [
        "film", "film.stack", "text.quote", "music.note", "music.note.list", "waveform",
        "textformat", "arrow.left.arrow.right.square", "wand.and.stars", "rectangle.stack.badge.play",
        "folder", "tray", "square.grid.2x2", "square.stack", "sparkles", "star", "heart", "flame",
        "bolt", "crown", "tag", "bookmark", "flag", "pin",
        "camera", "video", "photo", "photo.stack", "eye", "light.max", "circle.lefthalf.filled",
        "camera.aperture", "timelapse", "slowmo", "livephoto",
        "speaker.wave.2", "mic", "music.mic", "headphones", "metronome", "pianokeys", "guitars",
        "globe", "map", "building.2", "house", "mountain.2", "tree", "leaf", "drop", "snowflake",
        "sun.max", "moon.stars", "cloud", "wind", "water.waves", "beach.umbrella",
        "person", "person.2", "figure.walk", "figure.run", "hand.wave", "theatermasks", "book",
        "car", "airplane", "bicycle", "sailboat", "paintbrush", "paintpalette", "scissors",
        "slider.horizontal.3", "dial.medium", "gauge.with.dots.needle.67percent",
        "briefcase", "cart", "creditcard", "chart.line.uptrend.xyaxis", "graduationcap",
        "gamecontroller", "trophy", "fork.knife", "cup.and.saucer", "pawprint", "gift",
        "clock", "calendar", "bell", "lightbulb", "puzzlepiece", "cube", "atom",
    ]
}

/// Picks the SF Symbol a category shows in the sidebar.
///
/// The whole set is offered rather than a curated handful, so it is browsed
/// and searched rather than typed: a name spelled by hand is a name that draws
/// nothing, and the grid can only ever yield one the system has.
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
        return MarketplaceSymbolCatalog.all.filter { name in
            name.contains(query) || MarketplaceSymbolCatalog.keywords[name]?.contains { $0.contains(query) } == true
        }
    }

    var body: some View {
        Button { browsing = true } label: {
            HStack(spacing: 8) {
                Image(systemName: preview).frame(width: 18, height: 18)
                Text(trimmed.isEmpty ? String(localized: "Default folder") : trimmed)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(trimmed.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.bordered)
        .help("Choose an SF Symbol for the sidebar row")
        .popover(isPresented: $browsing, arrowEdge: .bottom) { browser }
        .accessibilityIdentifier("marketplace-symbol-picker")
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search symbols", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("marketplace-symbol-search")
            if matches.isEmpty {
                Text("No symbol matches that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
            }
            Divider()
            HStack {
                Text("\(matches.count) symbols")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Use the Default Folder") {
                    symbol = ""
                    browsing = false
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 420, height: 360)
    }
}
