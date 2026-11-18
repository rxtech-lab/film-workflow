import Foundation
import SwiftData

extension RemotionProject {
    var compositionSourceURL: URL { projectDir.appendingPathComponent("src/Composition.tsx") }

    /// Copies `src/Composition.tsx` from disk into the document when a native editor changed
    /// it, and tells open previews (footage, live timeline layers, the MotionSwift sequence
    /// stage) to reload. Returns whether anything changed.
    @discardableResult
    func syncCompositionSourceFromDisk(context: ModelContext) -> Bool {
        guard let source = try? String(contentsOf: compositionSourceURL, encoding: .utf8), source != compositionSource else { return false }
        compositionSource = source
        updatedAt = Date()
        try? context.save()
        NotificationCenter.default.post(name: .remotionPreviewChanged, object: nil,
                                        userInfo: ["directory": projectDir.standardizedFileURL])
        return true
    }
}
