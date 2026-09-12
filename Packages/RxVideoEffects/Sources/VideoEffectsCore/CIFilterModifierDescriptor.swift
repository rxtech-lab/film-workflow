import CoreImage
import Foundation

/// A marketplace effect or transition: a built-in Core Image filter plus how
/// the inspector's controls map onto its input keys. Decoded from the item's
/// `content.json`; `validate()` checks it against the filters this system has.
public struct CIFilterModifierDescriptor: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case effect, transition }
    public enum Curve: String, Codable, Sendable { case linear, easeInOut }
    /// Multiply a relative number by a picture dimension, so preview and export match.
    public enum Scale: String, Codable, Sendable { case none, shortSide, width, height }

    public struct Inputs: Codable, Hashable, Sendable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    public enum Control: Hashable, Sendable {
        case number(min: Double, max: Double, step: Double)
        /// `map` turns a label into the number the filter wants; without it the label itself is set.
        case choice(options: [String], map: [String: Double]?)
        case color
    }

    public struct Parameter: Codable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var filterKey: String
        public var control: Control
        public var defaultValue: ModifierValue
        public var scale: Scale?

        enum CodingKeys: String, CodingKey { case id, title, filterKey, control, defaultValue = "default", scale }

        public init(id: String, title: String, filterKey: String, control: Control, defaultValue: ModifierValue, scale: Scale? = nil) {
            self.id = id; self.title = title; self.filterKey = filterKey; self.control = control; self.defaultValue = defaultValue; self.scale = scale
        }
    }

    public var format: Int
    public var id: String
    public var kind: Kind
    public var name: String
    public var summary: String
    public var filter: String
    public var progressKey: String?
    public var progressCurve: Curve?
    public var inputs: Inputs?
    public var parameters: [Parameter]
    /// Filter inputs set without a control: `$extent`, `$center`, `$color:#rrggbb`, or a number.
    public var constants: [String: String]?
    /// Effects only: extend the picture's edge pixels outward before filtering,
    /// so blurs and other neighbourhood filters do not fade at the border.
    /// Off by default because filters that read the extent (a vignette) need the real one.
    public var clampEdges: Bool

    public static let supportedFormat = 1

    public init(
        format: Int = CIFilterModifierDescriptor.supportedFormat,
        id: String,
        kind: Kind,
        name: String,
        summary: String = "",
        filter: String,
        progressKey: String? = nil,
        progressCurve: Curve? = nil,
        inputs: Inputs? = nil,
        parameters: [Parameter] = [],
        constants: [String: String]? = nil,
        clampEdges: Bool = false
    ) {
        self.format = format; self.id = id; self.kind = kind; self.name = name; self.summary = summary; self.filter = filter
        self.progressKey = progressKey; self.progressCurve = progressCurve; self.inputs = inputs; self.parameters = parameters; self.constants = constants
        self.clampEdges = clampEdges
    }

    enum CodingKeys: String, CodingKey { case format, id, kind, name, summary, filter, progressKey, progressCurve, inputs, parameters, constants, clampEdges }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? Self.supportedFormat
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        filter = try c.decode(String.self, forKey: .filter)
        progressKey = try c.decodeIfPresent(String.self, forKey: .progressKey)
        progressCurve = try c.decodeIfPresent(Curve.self, forKey: .progressCurve)
        inputs = try c.decodeIfPresent(Inputs.self, forKey: .inputs)
        parameters = try c.decodeIfPresent([Parameter].self, forKey: .parameters) ?? []
        constants = try c.decodeIfPresent([String: String].self, forKey: .constants)
        clampEdges = try c.decodeIfPresent(Bool.self, forKey: .clampEdges) ?? false
    }

    public static func decode(_ data: Data) throws -> CIFilterModifierDescriptor {
        try JSONDecoder().decode(CIFilterModifierDescriptor.self, from: data)
    }

    // MARK: - Validation

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case unsupportedFormat(Int)
        case unknownFilter(String)
        case notATransition(String)
        case missingInputImage(String)
        case missingProgressKey
        case unknownInputKey(String)
        case duplicateParameter(String)
        case invalidDefault(String)
        case invalidRange(String)

        public var description: String {
            switch self {
            case .unsupportedFormat(let format): return "Unsupported descriptor format \(format)."
            case .unknownFilter(let name): return "Core Image has no filter named \(name)."
            case .notATransition(let name): return "\(name) is not a transition filter."
            case .missingInputImage(let name): return "\(name) does not take an input picture."
            case .missingProgressKey: return "Transitions need a progressKey."
            case .unknownInputKey(let key): return "The filter has no input named \(key)."
            case .duplicateParameter(let id): return "Parameter \(id) appears twice."
            case .invalidDefault(let id): return "Parameter \(id) has a default that does not fit its control."
            case .invalidRange(let id): return "Parameter \(id) has an empty range."
            }
        }
    }

    /// Checks the descriptor against the filters and input keys this system actually has.
    public func validate() throws {
        guard format == Self.supportedFormat else { throw ValidationError.unsupportedFormat(format) }
        guard let ciFilter = CIFilter(name: filter) else { throw ValidationError.unknownFilter(filter) }
        let inputKeys = Set(ciFilter.inputKeys)
        let categories = (ciFilter.attributes[kCIAttributeFilterCategories] as? [String]) ?? []
        switch kind {
        case .effect:
            guard inputKeys.contains(kCIInputImageKey) else { throw ValidationError.missingInputImage(filter) }
        case .transition:
            guard categories.contains(kCICategoryTransition) else { throw ValidationError.notATransition(filter) }
            guard let progressKey else { throw ValidationError.missingProgressKey }
            for key in [progressKey, resolvedInputs.from, resolvedInputs.to] where !inputKeys.contains(key) {
                throw ValidationError.unknownInputKey(key)
            }
        }
        var seen = Set<String>()
        for parameter in parameters {
            guard seen.insert(parameter.id).inserted else { throw ValidationError.duplicateParameter(parameter.id) }
            guard inputKeys.contains(parameter.filterKey) else { throw ValidationError.unknownInputKey(parameter.filterKey) }
            switch (parameter.control, parameter.defaultValue) {
            case (.number(let min, let max, _), .number):
                if min >= max { throw ValidationError.invalidRange(parameter.id) }
            case (.choice(let options, _), .string(let value)):
                if !options.contains(value) { throw ValidationError.invalidDefault(parameter.id) }
            case (.color, .string):
                break
            default:
                throw ValidationError.invalidDefault(parameter.id)
            }
        }
        for key in (constants ?? [:]).keys where !inputKeys.contains(key) {
            throw ValidationError.unknownInputKey(key)
        }
    }

    var resolvedInputs: Inputs { inputs ?? Inputs(from: kCIInputImageKey, to: kCIInputTargetImageKey) }

    /// The inspector controls, in the vocabulary the editor already renders.
    public var modifierParameters: [ModifierParameter] {
        parameters.map { parameter in
            let control: ModifierParameter.Control
            switch parameter.control {
            case .number(let min, let max, let step): control = .number(min...max, step: step)
            case .choice(let options, _): control = .choice(options)
            case .color: control = .color
            }
            return ModifierParameter(parameter.id, parameter.title, control: control, defaultValue: parameter.defaultValue)
        }
    }
}

extension CIFilterModifierDescriptor.Control: Codable {
    private enum CodingKeys: String, CodingKey { case type, min, max, step, options, map }
    private enum Kind: String, Codable { case number, choice, color }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .number:
            self = .number(min: try c.decode(Double.self, forKey: .min), max: try c.decode(Double.self, forKey: .max), step: try c.decodeIfPresent(Double.self, forKey: .step) ?? 0.01)
        case .choice:
            self = .choice(options: try c.decode([String].self, forKey: .options), map: try c.decodeIfPresent([String: Double].self, forKey: .map))
        case .color:
            self = .color
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .number(let min, let max, let step):
            try c.encode(Kind.number, forKey: .type); try c.encode(min, forKey: .min); try c.encode(max, forKey: .max); try c.encode(step, forKey: .step)
        case .choice(let options, let map):
            try c.encode(Kind.choice, forKey: .type); try c.encode(options, forKey: .options); try c.encodeIfPresent(map, forKey: .map)
        case .color:
            try c.encode(Kind.color, forKey: .type)
        }
    }
}
