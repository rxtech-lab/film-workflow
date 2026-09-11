import CoreImage
import Foundation

public struct BrightnessContrast: EffectProtocol {
    public init() {}
    public let id = "rx.brightness-contrast"
    public let name = "Brightness / Contrast"
    public let summary = "Lighten or darken the picture and adjust the separation between shadows and highlights."
    public let parameters = [
        ModifierParameter("brightness", "Brightness", control: .number(-1...1, step: 0.01), defaultValue: .number(0.1)),
        ModifierParameter("contrast", "Contrast", control: .number(0...4, step: 0.01), defaultValue: .number(1.1)),
    ]
    public func render(_ image: CIImage, parameters p: ModifierParameters) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: ["inputBrightness": max(-1, min(1, p.number("brightness", default: 0.1))),
                                                            "inputContrast": max(0, min(4, p.number("contrast", default: 1.1)))])
    }
}

public struct Saturation: EffectProtocol {
    public init() {}
    public let id = "rx.saturation"
    public let name = "Saturation"
    public let summary = "Control color intensity, from black and white to vivid color."
    public let parameters = [ModifierParameter("amount", "Saturation", control: .number(0...2, step: 0.01), defaultValue: .number(0))]
    public func render(_ image: CIImage, parameters p: ModifierParameters) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: ["inputSaturation": max(0, min(2, p.number("amount")))])
    }
}

public struct GaussianBlur: EffectProtocol {
    public init() {}
    public let id = "rx.gaussian-blur"
    public let name = "Gaussian Blur"
    public let summary = "Soften details with a smooth blur. Radius is relative to the picture size, so preview and export match."
    public let parameters = [ModifierParameter("radius", "Radius (%)", control: .number(0...10, step: 0.1), defaultValue: .number(1))]
    public func render(_ image: CIImage, parameters p: ModifierParameters) -> CIImage {
        let radius = min(image.extent.width, image.extent.height) * max(0, min(10, p.number("radius", default: 1))) / 100
        return image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius]).cropped(to: image.extent)
    }
}

public struct CrossDissolve: TransitionProtocol {
    public init() {}
    public let id = "rx.cross-dissolve"
    public let name = "Cross Dissolve"
    public let summary = "Blend smoothly between two clips. At a single clip edge, fade the picture to or from the layers beneath it."
    public let parameters = [ModifierParameter("curve", "Curve", control: .choice(["Linear", "Ease In Out"]), defaultValue: .string("Linear"))]
    public func render(from: CIImage, to: CIImage, progress: Double, parameters: ModifierParameters) -> CIImage {
        ModifierRendering.dissolve(from, to, progress: ModifierRendering.progress(progress, parameters: parameters))
    }
}

public struct FadeThroughColor: TransitionProtocol {
    public init() {}
    public let id = "rx.fade-color"
    public let name = "Fade through Color"
    public let summary = "Fade through a solid color between clips, or fade from or to that color at a single clip edge."
    public let parameters = [ModifierParameter("color", "Color", control: .color, defaultValue: .string("#000000"))]
    public func renderEdge(_ image: CIImage, progress: Double, atStart: Bool, parameters p: ModifierParameters) -> CIImage {
        let color = CIImage(color: ModifierRendering.color(p.string("color", default: "#000000"))).cropped(to: image.extent)
        return ModifierRendering.dissolve(atStart ? color : image, atStart ? image : color, progress: progress)
    }
    public func render(from: CIImage, to: CIImage, progress: Double, parameters p: ModifierParameters) -> CIImage {
        let t = min(1, max(0, progress))
        let color = CIImage(color: ModifierRendering.color(p.string("color", default: "#000000"))).cropped(to: from.extent)
        return t < 0.5 ? ModifierRendering.dissolve(from, color, progress: t * 2)
            : ModifierRendering.dissolve(color, to, progress: (t - 0.5) * 2)
    }
}

public struct DirectionalWipe: TransitionProtocol {
    public init() {}
    public let id = "rx.directional-wipe"
    public let name = "Directional Wipe"
    public let summary = "Reveal the next picture along a moving edge. A single-clip wipe reveals or clears the picture over underlying layers."
    public let parameters = [ModifierParameter("direction", "Direction", control: .choice(["Left", "Right", "Up", "Down"]), defaultValue: .string("Right"))]
    public func render(from: CIImage, to: CIImage, progress: Double, parameters p: ModifierParameters) -> CIImage {
        let t = min(1, max(0, progress)), frame = from.extent
        if t <= 0 { return from }; if t >= 1 { return to }
        var reveal = frame
        switch p.string("direction", default: "Right") {
        case "Left": reveal.origin.x += frame.width * (1 - t); reveal.size.width *= t
        case "Up": reveal.size.height *= t
        case "Down": reveal.origin.y += frame.height * (1 - t); reveal.size.height *= t
        default: reveal.size.width *= t
        }
        let mask = CIImage(color: .white).cropped(to: reveal).composited(over: CIImage(color: .black).cropped(to: frame))
        return to.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: from, kCIInputMaskImageKey: mask]).cropped(to: frame)
    }
}

public enum ModifierRendering {
    public static func dissolve(_ from: CIImage, _ to: CIImage, progress: Double) -> CIImage {
        from.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: to, kCIInputTimeKey: min(1, max(0, progress))]).cropped(to: from.extent)
    }
    public static func progress(_ value: Double, parameters: ModifierParameters) -> Double {
        let t = max(0, min(1, value))
        return parameters.string("curve") == "Ease In Out" ? t * t * (3 - 2 * t) : t
    }
    public static func color(_ hex: String) -> CIColor {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return CIColor(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
