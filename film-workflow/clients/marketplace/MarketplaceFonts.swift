import CoreText
import Foundation

/// Process-scope registration for installed font items. Registration does not
/// survive relaunch, so `registerInstalled` runs at startup and `register`
/// runs again after each install.
nonisolated enum MarketplaceFonts {
    @discardableResult
    static func register(_ url: URL) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // Already registered in this process counts as success.
        if let code = error?.takeRetainedValue(), CFErrorGetCode(code) == CTFontManagerError.alreadyRegistered.rawValue { return true }
        return false
    }

    static func unregister(_ url: URL) {
        var error: Unmanaged<CFError>?
        _ = CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &error)
        error?.release()
    }

    /// The family name the picker should show, read from the file itself.
    static func familyName(of url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
    }

    /// Registers every installed font item. Returns how many succeeded.
    @discardableResult
    static func registerInstalled(root: URL = FileStorage.marketplaceDir) -> Int {
        MarketplaceStore.scanInstalled(root: root).values
            .filter { $0.kind == .font }
            .reduce(0) { count, manifest in
                let directory = FileStorage.marketplaceItemDir(kind: manifest.kind.rawValue, itemID: manifest.itemID, root: root)
                return count + (register(manifest.contentURL(in: directory)) ? 1 : 0)
            }
    }
}
