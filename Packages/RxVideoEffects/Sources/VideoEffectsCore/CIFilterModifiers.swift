import CoreImage
import Foundation

/// Sets a descriptor's controls and constants on a freshly made filter.
/// Shared by the effect and transition wrappers so both clamp, scale and map
/// values the same way.
enum CIFilterBinding {
    static func apply(_ descriptor: CIFilterModifierDescriptor, to filter: CIFilter, parameters: ModifierParameters, extent: CGRect) {
        for parameter in descriptor.parameters {
            let value = parameters[parameter.id] ?? parameter.defaultValue
            switch parameter.control {
            case .number(let min, let max, _):
                guard case .number(let raw) = value, raw.isFinite else { continue }
                let clamped = Swift.max(min, Swift.min(max, raw))
                filter.setValue(scaled(clamped, by: parameter.scale, in: extent), forKey: parameter.filterKey)
            case .choice(let options, let map):
                guard case .string(let label) = value, options.contains(label) else { continue }
                if let map { if let number = map[label] { filter.setValue(number, forKey: parameter.filterKey) } }
                else { filter.setValue(label, forKey: parameter.filterKey) }
            case .color:
                guard case .string(let hex) = value else { continue }
                filter.setValue(ModifierRendering.color(hex), forKey: parameter.filterKey)
            }
        }
        for (key, literal) in descriptor.constants ?? [:] {
            if let value = constant(literal, extent: extent) { filter.setValue(value, forKey: key) }
        }
    }

    private static func scaled(_ value: Double, by scale: CIFilterModifierDescriptor.Scale?, in extent: CGRect) -> Double {
        switch scale ?? .none {
        case .none: return value
        case .shortSide: return value * Swift.min(extent.width, extent.height)
        case .width: return value * extent.width
        case .height: return value * extent.height
        }
    }

    private static func constant(_ literal: String, extent: CGRect) -> Any? {
        switch literal {
        case "$extent": return CIVector(cgRect: extent)
        case "$center": return CIVector(x: extent.midX, y: extent.midY)
        default:
            if literal.hasPrefix("$color:") { return ModifierRendering.color(String(literal.dropFirst("$color:".count))) }
            return Double(literal)
        }
    }
}

/// An effect defined entirely by a descriptor. The filter is created per
/// render: `CIFilter` instances are not thread-safe, and creation is cheap.
public struct CIFilterEffect: EffectProtocol {
    public let descriptor: CIFilterModifierDescriptor
    public let parameters: [ModifierParameter]

    public init(_ descriptor: CIFilterModifierDescriptor) {
        self.descriptor = descriptor
        self.parameters = descriptor.modifierParameters
    }

    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
    public var summary: String { descriptor.summary }

    public func render(_ image: CIImage, parameters: ModifierParameters) -> CIImage {
        guard let filter = CIFilter(name: descriptor.filter) else { return image }
        filter.setValue(descriptor.clampEdges ? image.clampedToExtent() : image, forKey: kCIInputImageKey)
        CIFilterBinding.apply(descriptor, to: filter, parameters: parameters, extent: image.extent)
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }
}

/// A transition defined entirely by a descriptor; `progressKey` receives the
/// curve-adjusted progress and `inputs` name the two picture keys.
public struct CIFilterTransition: TransitionProtocol {
    public let descriptor: CIFilterModifierDescriptor
    public let parameters: [ModifierParameter]

    public init(_ descriptor: CIFilterModifierDescriptor) {
        self.descriptor = descriptor
        self.parameters = descriptor.modifierParameters
    }

    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
    public var summary: String { descriptor.summary }

    public func render(from: CIImage, to: CIImage, progress: Double, parameters: ModifierParameters) -> CIImage {
        let t = min(1, max(0, progress))
        if t <= 0 { return from }
        if t >= 1 { return to }
        guard let filter = CIFilter(name: descriptor.filter), let progressKey = descriptor.progressKey else {
            return ModifierRendering.dissolve(from, to, progress: t)
        }
        let inputs = descriptor.resolvedInputs
        filter.setValue(from, forKey: inputs.from)
        filter.setValue(to, forKey: inputs.to)
        let eased = descriptor.progressCurve == .easeInOut ? t * t * (3 - 2 * t) : t
        filter.setValue(eased, forKey: progressKey)
        CIFilterBinding.apply(descriptor, to: filter, parameters: parameters, extent: from.extent)
        return filter.outputImage?.cropped(to: from.extent) ?? ModifierRendering.dissolve(from, to, progress: t)
    }
}
