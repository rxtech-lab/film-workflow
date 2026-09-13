import Foundation
import VideoEffectsCore

/// Turns installed effect and transition items into catalog definitions.
///
/// Reads `Marketplace/effect/*/` and `Marketplace/transition/*/`, decodes each
/// item's descriptor, validates it against the Core Image filters this system
/// has, and hands the result to `ModifierCatalog.setInstalled`. A file that
/// fails to load is skipped, never fatal: the browser shows what did load.
nonisolated enum InstalledModifierLoader {
    static func descriptor(at url: URL, expecting kind: MarketplaceKind) throws -> CIFilterModifierDescriptor {
        let descriptor: CIFilterModifierDescriptor
        do {
            descriptor = try CIFilterModifierDescriptor.decode(try Data(contentsOf: url))
        } catch {
            throw MarketplaceError.invalidDescriptor(String(localized: "the descriptor file is not valid JSON."))
        }
        let expected: CIFilterModifierDescriptor.Kind = kind == .transition ? .transition : .effect
        guard descriptor.kind == expected else {
            throw MarketplaceError.invalidDescriptor(String(localized: "it describes a \(descriptor.kind.rawValue), not a \(kind.rawValue)."))
        }
        do { try descriptor.validate() } catch let failure as CIFilterModifierDescriptor.ValidationError {
            throw MarketplaceError.invalidDescriptor(failure.description)
        }
        return descriptor
    }

    static func load(root: URL) -> ModifierCatalog {
        var effects: [any EffectProtocol] = []
        var transitions: [any TransitionProtocol] = []
        var previews: [String: URL] = [:]
        for (kind, manifest) in MarketplaceStore.scanInstalled(root: root).map({ ($0.value.kind, $0.value) })
        where kind == .effect || kind == .transition {
            let directory = FileStorage.marketplaceItemDir(kind: kind.rawValue, itemID: manifest.itemID, root: root)
            guard let descriptor = try? descriptor(at: manifest.contentURL(in: directory), expecting: kind) else { continue }
            switch descriptor.kind {
            case .effect: effects.append(CIFilterEffect(descriptor))
            case .transition: transitions.append(CIFilterTransition(descriptor))
            }
            if let preview = manifest.previewURL(in: directory) { previews[descriptor.id] = preview }
        }
        let byID: (any ModifierDefinition, any ModifierDefinition) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ModifierCatalog(effects: effects.sorted(by: byID), transitions: transitions.sorted(by: byID), previewURLs: previews)
    }

    static func reload(root: URL = FileStorage.marketplaceDir) {
        ModifierCatalog.setInstalled(load(root: root))
    }
}
