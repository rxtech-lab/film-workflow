import AppKit

/// SwiftUI's virtual accessibility nodes expose accessibility selectors without
/// declaring NSAccessibilityProtocol conformance. Traverse both kinds of node.
@MainActor
struct HostedAccessibilityElement {
    let object: NSObject
    private var modern: (any NSAccessibilityProtocol)? { object as? any NSAccessibilityProtocol }
    func property(_ name: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(name)) else { return nil }
        return object.value(forKey: name)
    }
    func accessibilityIdentifier() -> String? {
        modern?.accessibilityIdentifier() ?? property("accessibilityIdentifier") as? String ?? object.accessibilityAttributeValue(.init(rawValue: "AXIdentifier")) as? String
    }
    func accessibilityLabel() -> String? {
        modern?.accessibilityLabel() ?? property("accessibilityLabel") as? String ?? object.accessibilityAttributeValue(.description) as? String
            ?? object.accessibilityAttributeValue(.title) as? String
    }
    func accessibilityValue() -> Any? { modern?.accessibilityValue() ?? property("accessibilityValue") ?? object.accessibilityAttributeValue(.value) }
    func accessibilityRole() -> NSAccessibility.Role? {
        modern?.accessibilityRole() ?? (object.accessibilityAttributeValue(.role) as? String).map(NSAccessibility.Role.init(rawValue:))
    }
    func accessibilityFrame() -> NSRect {
        if let modern { return modern.accessibilityFrame() }
        if let frame = property("accessibilityFrame") as? NSValue { return frame.rectValue }
        let point = (object.accessibilityAttributeValue(.position) as? NSValue)?.pointValue ?? .zero
        let size = (object.accessibilityAttributeValue(.size) as? NSValue)?.sizeValue ?? .zero
        return NSRect(origin: point, size: size)
    }
    func accessibilityPerformPress() -> Bool {
        if let modern { return modern.accessibilityPerformPress() }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        if object.responds(to: selector), let method = object.method(for: selector) {
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Press.self)(object, selector)
        }
        guard object.accessibilityActionNames().contains(.press) else { return false }
        object.accessibilityPerformAction(.press)
        return true
    }
}

@MainActor
func hostedAccessibilityDescendants(_ value: Any) -> [HostedAccessibilityElement] {
    var visited: Set<ObjectIdentifier> = []
    func walk(_ value: Any, depth: Int) -> [HostedAccessibilityElement] {
        guard depth < 25, let object = value as? NSObject,
              visited.insert(ObjectIdentifier(object)).inserted else { return [] }
        let element = HostedAccessibilityElement(object: object)
        let children = (element.property("accessibilityChildren") as? [Any] ?? object.accessibilityAttributeValue(.children) as? [Any] ?? [])
            + (element.property("accessibilityContents") as? [Any] ?? object.accessibilityAttributeValue(.contents) as? [Any] ?? [])
            + (element.property("accessibilityVisibleChildren") as? [Any] ?? object.accessibilityAttributeValue(.visibleChildren) as? [Any] ?? [])
        return [HostedAccessibilityElement(object: object)] + children.flatMap { walk($0, depth: depth + 1) }
    }
    return walk(value, depth: 0)
}
