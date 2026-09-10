import Foundation

/// Optional presentation state, kept separate from the film's required metadata.
struct DocumentPanelLayout: Codable, Equatable {
    enum Panel: String {
        case editorColumns, editorRows, libraryRows
    }

    var splits: [String: [Double]] = [:]

    func sizes(for panel: Panel) -> [Double]? {
        guard let sizes = splits[panel.rawValue], sizes.count >= 2,
              sizes.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return sizes
    }
}
