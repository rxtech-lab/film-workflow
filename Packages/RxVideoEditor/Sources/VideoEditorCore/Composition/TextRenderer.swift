import AppKit
import CoreImage
import Foundation

/// Rasterises caption text into images the compositor can place. Cached by
/// text, style and frame size, because a cue is drawn on every frame it spans.
public final class TextRenderer: @unchecked Sendable {
    public static let shared = TextRenderer()

    private struct Key: Hashable {
        let text: String
        let style: TextStyle
        let width: Int
        let height: Int
    }

    private let lock = NSLock()
    private var cache: [Key: CIImage] = [:]

    /// An image the width of the frame with the text box drawn where the
    /// style places it, transparent elsewhere.
    public func image(for text: String, style: TextStyle, frameSize: CGSize) -> CIImage? {
        let key = Key(text: text, style: style, width: Int(frameSize.width), height: Int(frameSize.height))
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        guard let image = render(text: text, style: style, frameSize: frameSize) else { return nil }
        lock.lock()
        if cache.count > 256 { cache.removeAll() }
        cache[key] = image
        lock.unlock()
        return image
    }

    /// The font a style resolves to at `pointSize`: the named family with the
    /// bold and italic traits applied, or the system font when the name is unknown.
    public static func font(for style: TextStyle, pointSize: CGFloat) -> NSFont {
        var font = NSFont(name: style.fontName, size: pointSize)
            ?? (style.bold ? NSFont.boldSystemFont(ofSize: pointSize) : NSFont.systemFont(ofSize: pointSize))
        if style.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    private func render(text: String, style: TextStyle, frameSize: CGSize) -> CIImage? {
        let width = Int(frameSize.width), height = Int(frameSize.height)
        guard width > 0, height > 0 else { return nil }
        let pointSize = max(8, frameSize.height * style.fontSize)
        let font = Self.font(for: style, pointSize: pointSize)

        let paragraph = NSMutableParagraphStyle()
        switch style.alignment {
        case .leading: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(hex: style.colorHex) ?? .white,
            .paragraphStyle: paragraph,
        ]
        if style.strokeWidth > 0 {
            // Negative width strokes and fills; positive would outline only.
            attributes[.strokeColor] = NSColor(hex: style.strokeHex) ?? .black
            attributes[.strokeWidth] = -(style.strokeWidth * 100)
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let margin = frameSize.width * 0.075
        let maxWidth = frameSize.width - margin * 2
        let bounds = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: frameSize.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let padding = pointSize * 0.35
        let boxSize = CGSize(width: ceil(bounds.width) + padding * 2, height: ceil(bounds.height) + padding * 2)
        let boxX: CGFloat
        switch style.alignment {
        case .leading: boxX = margin
        case .center: boxX = (frameSize.width - boxSize.width) / 2
        case .trailing: boxX = frameSize.width - margin - boxSize.width
        }
        let boxOrigin = CGPoint(
            x: boxX,
            // AppKit's flipped context: y grows downward, position 1 = bottom.
            y: (frameSize.height - boxSize.height) * style.verticalPosition
        )

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        // Flip so AppKit's top-left origin lands on CG's bottom-left bitmap.
        context.translateBy(x: 0, y: frameSize.height)
        context.scaleBy(x: 1, y: -1)

        if style.backgroundOpacity > 0, let background = NSColor(hex: style.backgroundHex) {
            background.withAlphaComponent(style.backgroundOpacity).setFill()
            NSBezierPath(roundedRect: CGRect(origin: boxOrigin, size: boxSize), xRadius: padding * 0.6, yRadius: padding * 0.6).fill()
        }
        attributed.draw(
            with: CGRect(x: boxOrigin.x + padding, y: boxOrigin.y + padding, width: boxSize.width - padding * 2, height: boxSize.height - padding * 2),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }
}

public extension NSColor {
    /// `#RRGGBB` or `#RRGGBBAA`.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// `#RRGGBB` in sRGB; alpha is dropped because styles carry it separately.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

extension CGColor {
    static func fromHex(_ hex: String) -> CGColor {
        NSColor(hex: hex)?.cgColor ?? CGColor(gray: 0, alpha: 1)
    }
}
