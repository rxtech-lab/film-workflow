import CoreImage
import Foundation
import os

public enum ModifierValue: Codable, Hashable, Sendable {
    case number(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Double.self) { self = .number(number) }
        else { self = .string(try value.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        }
    }
}

public typealias ModifierParameters = [String: ModifierValue]

public extension Dictionary where Key == String, Value == ModifierValue {
    func number(_ key: String, default fallback: Double = 0) -> Double {
        if case .number(let value) = self[key], value.isFinite { return value }
        return fallback
    }
    func string(_ key: String, default fallback: String = "") -> String {
        if case .string(let value) = self[key] { return value }
        return fallback
    }
}

public struct ModifierParameter: Identifiable, Sendable {
    public enum Control: Sendable {
        case number(ClosedRange<Double>, step: Double)
        case choice([String])
        case color
    }
    public let id: String
    public let title: String
    public let control: Control
    public let defaultValue: ModifierValue

    public init(_ id: String, _ title: String, control: Control, defaultValue: ModifierValue) {
        self.id = id; self.title = title; self.control = control; self.defaultValue = defaultValue
    }
}

/// Rendering and inspector metadata travel together, independently of any editor model.
public protocol ModifierDefinition: Sendable {
    var id: String { get }
    var name: String { get }
    var summary: String { get }
    var parameters: [ModifierParameter] { get }
}

public extension ModifierDefinition {
    var defaults: ModifierParameters { Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.defaultValue) }) }
}

public protocol EffectProtocol: ModifierDefinition {
    func render(_ image: CIImage, parameters: ModifierParameters) -> CIImage
}

public protocol TransitionProtocol: ModifierDefinition {
    /// Inputs have the same canvas extent, with premultiplied alpha. Progress is 0...1.
    func render(from: CIImage, to: CIImage, progress: Double, parameters: ModifierParameters) -> CIImage
    func renderEdge(_ image: CIImage, progress: Double, atStart: Bool, parameters: ModifierParameters) -> CIImage
}

public extension TransitionProtocol {
    func renderEdge(_ image: CIImage, progress: Double, atStart: Bool, parameters: ModifierParameters) -> CIImage {
        let clear = CIImage(color: .clear).cropped(to: image.extent)
        return render(from: atStart ? clear : image, to: atStart ? image : clear, progress: progress, parameters: parameters)
    }
}

public struct EffectInstance: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var definitionID: String
    public var parameters: ModifierParameters
    public var isEnabled: Bool

    public init(id: UUID = UUID(), definitionID: String, parameters: ModifierParameters = [:], isEnabled: Bool = true) {
        self.id = id; self.definitionID = definitionID; self.parameters = parameters; self.isEnabled = isEnabled
    }
}

public enum ModifierKind: String, Codable, Hashable, Sendable { case effect, transition }

public struct ModifierDragItem: Codable, Hashable, Sendable {
    public var kind: ModifierKind
    public var definitionID: String
    public init(kind: ModifierKind, definitionID: String) { self.kind = kind; self.definitionID = definitionID }
}

/// An immutable catalog value. `standard` is what ships in the binary;
/// `installed` is what the host loaded from disk; `current` is the two merged
/// and is what every consumer reads.
public struct ModifierCatalog: Sendable {
    public let effects: [any EffectProtocol]
    public let transitions: [any TransitionProtocol]
    /// Definition ID → a still the browser shows instead of a synthesized sample. Installed definitions only.
    public let previewURLs: [String: URL]

    public init(effects: [any EffectProtocol], transitions: [any TransitionProtocol], previewURLs: [String: URL] = [:]) {
        self.effects = effects; self.transitions = transitions; self.previewURLs = previewURLs
    }
    public static let standard = ModifierCatalog(
        effects: [BrightnessContrast(), Saturation(), GaussianBlur()],
        transitions: [CrossDissolve(), FadeThroughColor(), DirectionalWipe()]
    )
    public static let empty = ModifierCatalog(effects: [], transitions: [])

    /// Posted after `setInstalled`, on whatever thread called it.
    public static let didChangeNotification = Notification.Name("ModifierCatalog.didChange")

    private struct Registry: Sendable { var installed = ModifierCatalog.empty; var current = ModifierCatalog.standard }
    private static let registry = OSAllocatedUnfairLock(initialState: Registry())

    /// Definitions the host loaded at runtime.
    public static var installed: ModifierCatalog { registry.withLock { $0.installed } }
    /// Built-ins plus installed definitions. Merged once per `setInstalled`, so
    /// reading it on the render path costs a lock and a copy of two arrays.
    public static var current: ModifierCatalog { registry.withLock { $0.current } }

    public static func setInstalled(_ catalog: ModifierCatalog) {
        registry.withLock { registry in
            registry.installed = catalog
            registry.current = standard.merging(catalog)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// `other` wins on a shared ID; everything else is appended in order.
    public func merging(_ other: ModifierCatalog) -> ModifierCatalog {
        let effectIDs = Set(other.effects.map(\.id)), transitionIDs = Set(other.transitions.map(\.id))
        return ModifierCatalog(
            effects: effects.filter { !effectIDs.contains($0.id) } + other.effects,
            transitions: transitions.filter { !transitionIDs.contains($0.id) } + other.transitions,
            previewURLs: previewURLs.merging(other.previewURLs) { $1 }
        )
    }

    public func effect(_ id: String) -> (any EffectProtocol)? { effects.first { $0.id == id } }
    public func transition(_ id: String) -> (any TransitionProtocol)? { transitions.first { $0.id == id } }
    public func definition(_ item: ModifierDragItem) -> (any ModifierDefinition)? {
        switch item.kind {
        case .effect: return effect(item.definitionID)
        case .transition: return transition(item.definitionID)
        }
    }
    public func apply(_ instances: [EffectInstance], to image: CIImage) -> CIImage {
        instances.filter(\.isEnabled).reduce(image) { image, instance in
            effect(instance.definitionID)?.render(image, parameters: instance.parameters) ?? image
        }
    }
}
