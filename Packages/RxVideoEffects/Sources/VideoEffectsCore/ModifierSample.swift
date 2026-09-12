import CoreImage
import Foundation

/// Bundled demo pictures are processed by the same definitions as actual footage.
public enum ModifierSample {
    private static let first = Bundle.module.url(forResource: "sample-a", withExtension: "png").flatMap { CIImage(contentsOf: $0) }
    private static let second = Bundle.module.url(forResource: "sample-b", withExtension: "png").flatMap { CIImage(contentsOf: $0) }

    public static func image(_ item: ModifierDragItem, progress: Double = 0.5, parameters: ModifierParameters? = nil, effectAmount: Double = 1) -> CIImage? {
        guard let a = first, let b = second else { return nil }
        let catalog = ModifierCatalog.current
        if item.kind == .effect, let effect = catalog.effect(item.definitionID) {
            let rendered = effect.render(a, parameters: parameters ?? effect.defaults)
            return effectAmount >= 1 ? rendered : CrossDissolve().render(from: a, to: rendered, progress: effectAmount, parameters: [:])
        }
        if let transition = catalog.transition(item.definitionID) {
            return transition.render(from: a, to: b, progress: progress, parameters: parameters ?? transition.defaults)
        }
        return a
    }
}
