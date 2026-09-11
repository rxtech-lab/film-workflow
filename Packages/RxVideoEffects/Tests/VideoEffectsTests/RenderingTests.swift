import CoreImage
import Foundation
import Testing
@testable import VideoEffectsCore

@Suite struct RenderingTests {
    let context = CIContext(options: [.useSoftwareRenderer: true])
    let frame = CGRect(x: 0, y: 0, width: 32, height: 32)
    func pixel(_ image: CIImage, x: Int = 16) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: 16, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return bytes
    }
    @Test func dissolveEndpointsAndTransparency() {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: frame)
        let clear = CIImage(color: .clear).cropped(to: frame)
        let effect = CrossDissolve()
        #expect(pixel(effect.render(from: red, to: clear, progress: 0, parameters: [:])) == [255, 0, 0, 255])
        #expect(pixel(effect.render(from: red, to: clear, progress: 1, parameters: [:])) == [0, 0, 0, 0])
        #expect(abs(Int(pixel(effect.render(from: red, to: clear, progress: 0.5, parameters: [:]))[3]) - 128) <= 1)
    }
    @Test func wipeDirectionAndFadeMidpoint() {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: frame)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: frame)
        let wiped = DirectionalWipe().render(from: red, to: blue, progress: 0.5, parameters: [:])
        #expect(pixel(wiped, x: 2) == [0, 0, 255, 255])
        #expect(pixel(wiped, x: 30) == [255, 0, 0, 255])
        #expect(pixel(FadeThroughColor().render(from: red, to: blue, progress: 0.5, parameters: [:])) == [0, 0, 0, 255])
    }
    @Test func orderedEffectsAndBypass() {
        let input = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5)).cropped(to: frame)
        let brighten = EffectInstance(definitionID: "rx.brightness-contrast", parameters: ["brightness": .number(0.2), "contrast": .number(1)])
        var contrast = EffectInstance(definitionID: "rx.brightness-contrast", parameters: ["brightness": .number(0), "contrast": .number(0.5)])
        let catalog = ModifierCatalog.standard
        let forward = catalog.apply([brighten, contrast], to: input)
        let backward = catalog.apply([contrast, brighten], to: input)
        #expect(pixel(forward) != pixel(backward))
        contrast.isEnabled = false
        #expect(pixel(catalog.apply([brighten, contrast], to: input)) == pixel(catalog.apply([brighten], to: input)))
        #expect(pixel(catalog.apply([EffectInstance(definitionID: "future")], to: input)) == pixel(input))
    }
    @Test func edgeTransitionColorAndAlpha() {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: frame)
        #expect(pixel(FadeThroughColor().renderEdge(red, progress: 0, atStart: true, parameters: ["color": .string("#0000FF")])) == [0, 0, 255, 255])
        #expect(pixel(CrossDissolve().renderEdge(red, progress: 0, atStart: true, parameters: [:]))[3] == 0)
        #expect(pixel(DirectionalWipe().renderEdge(red, progress: 1, atStart: false, parameters: [:]))[3] == 0)
    }
    @Test func catalogAndUnknownInstanceRoundTrip() throws {
        #expect(ModifierCatalog.standard.effects.count == 3)
        #expect(ModifierCatalog.standard.transitions.count == 3)
        let unknown = EffectInstance(definitionID: "future.effect", parameters: ["future": .string("keep me")])
        let decoded = try JSONDecoder().decode(EffectInstance.self, from: JSONEncoder().encode(unknown))
        #expect(decoded == unknown)
        for effect in ModifierCatalog.standard.effects {
            #expect(ModifierSample.image(.init(kind: .effect, definitionID: effect.id)) != nil)
        }
    }
}
