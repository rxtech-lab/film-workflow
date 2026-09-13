import CoreImage
import Foundation
import Testing
@testable import VideoEffectsCore

@Suite(.serialized) struct CIFilterDescriptorTests {
    let context = CIContext(options: [.useSoftwareRenderer: true])
    let frame = CGRect(x: 0, y: 0, width: 32, height: 32)
    func pixel(_ image: CIImage, x: Int = 16) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: 16, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return bytes
    }

    static let swipeJSON = """
    {
      "format": 1, "id": "mp.swipe", "kind": "transition", "name": "Swipe", "summary": "A sliding edge.",
      "filter": "CISwipeTransition", "progressKey": "inputTime", "progressCurve": "linear",
      "inputs": { "from": "inputImage", "to": "inputTargetImage" },
      "parameters": [
        { "id": "angle", "title": "Angle", "filterKey": "inputAngle", "control": { "type": "number", "min": 0, "max": 6.283, "step": 0.01 }, "default": 0 },
        { "id": "width", "title": "Width", "filterKey": "inputWidth", "control": { "type": "number", "min": 0, "max": 1, "step": 0.01 }, "default": 0.02, "scale": "shortSide" }
      ],
      "constants": { "inputExtent": "$extent", "inputColor": "$color:#000000" }
    }
    """

    static let vignetteJSON = """
    { "id": "mp.vignette", "kind": "effect", "name": "Vignette", "filter": "CIVignette",
      "parameters": [ { "id": "intensity", "title": "Intensity", "filterKey": "inputIntensity", "control": { "type": "number", "min": 0, "max": 1, "step": 0.01 }, "default": 1 },
                      { "id": "radius", "title": "Radius", "filterKey": "inputRadius", "control": { "type": "number", "min": 0, "max": 2, "step": 0.01 }, "default": 2 } ] }
    """

    @Test func decodesAndValidatesTheReferenceDescriptors() throws {
        let swipe = try CIFilterModifierDescriptor.decode(Data(Self.swipeJSON.utf8))
        #expect(swipe.kind == .transition)
        #expect(swipe.parameters.count == 2)
        #expect(swipe.parameters[1].scale == .shortSide)
        try swipe.validate()
        let vignette = try CIFilterModifierDescriptor.decode(Data(Self.vignetteJSON.utf8))
        #expect(vignette.format == 1)
        #expect(vignette.summary.isEmpty)
        try vignette.validate()
        let roundTrip = try JSONDecoder().decode(CIFilterModifierDescriptor.self, from: JSONEncoder().encode(swipe))
        #expect(roundTrip == swipe)
    }

    @Test func rejectsUnknownFiltersKeysAndMismatches() throws {
        var descriptor = try CIFilterModifierDescriptor.decode(Data(Self.swipeJSON.utf8))
        descriptor.filter = "CINotAFilter"
        #expect(throws: CIFilterModifierDescriptor.ValidationError.unknownFilter("CINotAFilter")) { try descriptor.validate() }
        descriptor.filter = "CIVignette"
        #expect(throws: CIFilterModifierDescriptor.ValidationError.notATransition("CIVignette")) { try descriptor.validate() }
        descriptor = try CIFilterModifierDescriptor.decode(Data(Self.swipeJSON.utf8))
        descriptor.progressKey = nil
        #expect(throws: CIFilterModifierDescriptor.ValidationError.missingProgressKey) { try descriptor.validate() }
        descriptor = try CIFilterModifierDescriptor.decode(Data(Self.swipeJSON.utf8))
        descriptor.parameters[0].filterKey = "inputNope"
        #expect(throws: CIFilterModifierDescriptor.ValidationError.unknownInputKey("inputNope")) { try descriptor.validate() }
        descriptor = try CIFilterModifierDescriptor.decode(Data(Self.swipeJSON.utf8))
        descriptor.parameters[1].id = "angle"
        #expect(throws: CIFilterModifierDescriptor.ValidationError.duplicateParameter("angle")) { try descriptor.validate() }
        descriptor = try CIFilterModifierDescriptor.decode(Data(Self.swipeJSON.utf8))
        descriptor.parameters[0].defaultValue = .string("Left")
        #expect(throws: CIFilterModifierDescriptor.ValidationError.invalidDefault("angle")) { try descriptor.validate() }
        var effect = try CIFilterModifierDescriptor.decode(Data(Self.vignetteJSON.utf8))
        effect.filter = "CIConstantColorGenerator"
        #expect(throws: CIFilterModifierDescriptor.ValidationError.missingInputImage("CIConstantColorGenerator")) { try effect.validate() }
        effect.format = 2
        #expect(throws: CIFilterModifierDescriptor.ValidationError.unsupportedFormat(2)) { try effect.validate() }
    }

    @Test func transitionEndpointsAndMidpointFollowTheFilter() throws {
        let descriptor = try CIFilterModifierDescriptor.decode(Data(Self.swipeJSON.utf8))
        let transition = CIFilterTransition(descriptor)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: frame)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: frame)
        #expect(pixel(transition.render(from: red, to: blue, progress: 0, parameters: [:])) == [255, 0, 0, 255])
        #expect(pixel(transition.render(from: red, to: blue, progress: 1, parameters: [:])) == [0, 0, 255, 255])
        let half = transition.render(from: red, to: blue, progress: 0.5, parameters: transition.defaults)
        // A swipe at angle 0 has revealed the left half and still shows the source on the right.
        #expect(pixel(half, x: 2) == [0, 0, 255, 255])
        #expect(pixel(half, x: 30) == [255, 0, 0, 255])
        #expect(transition.parameters.map(\.id) == ["angle", "width"])
    }

    @Test func effectAppliesClampedParameters() throws {
        let descriptor = try CIFilterModifierDescriptor.decode(Data(Self.vignetteJSON.utf8))
        #expect(descriptor.clampEdges == false)
        let effect = CIFilterEffect(descriptor)
        let grey = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: frame)
        let corner = pixel(effect.render(grey, parameters: ["intensity": .number(1), "radius": .number(2)]), x: 1)
        let untouched = pixel(effect.render(grey, parameters: ["intensity": .number(0)]), x: 1)
        #expect(corner[0] < untouched[0])
        #expect(untouched == pixel(grey, x: 1))
        // Out-of-range values clamp instead of reaching the filter.
        #expect(pixel(effect.render(grey, parameters: ["intensity": .number(50)]), x: 1) == corner)
    }

    @Test func installedDefinitionsMergeIntoCurrent() throws {
        defer { ModifierCatalog.setInstalled(.empty) }
        let swipe = CIFilterTransition(try CIFilterModifierDescriptor.decode(Data(Self.swipeJSON.utf8)))
        let vignette = CIFilterEffect(try CIFilterModifierDescriptor.decode(Data(Self.vignetteJSON.utf8)))
        let override = CIFilterEffect(CIFilterModifierDescriptor(id: "rx.saturation", kind: .effect, name: "Replaced", filter: "CIColorControls"))
        let preview = URL(fileURLWithPath: "/tmp/preview.jpg")
        ModifierCatalog.setInstalled(ModifierCatalog(effects: [vignette, override], transitions: [swipe], previewURLs: [swipe.id: preview]))
        let current = ModifierCatalog.current
        #expect(current.effects.count == ModifierCatalog.standard.effects.count + 1)
        #expect(current.effect("rx.saturation")?.name == "Replaced")
        #expect(current.transition("mp.swipe") != nil)
        #expect(current.previewURLs["mp.swipe"] == preview)
        #expect(ModifierCatalog.standard.effect("rx.saturation")?.name == "Saturation")
        #expect(ModifierSample.image(.init(kind: .transition, definitionID: "mp.swipe")) != nil)
        ModifierCatalog.setInstalled(.empty)
        #expect(ModifierCatalog.current.transition("mp.swipe") == nil)
    }
}
