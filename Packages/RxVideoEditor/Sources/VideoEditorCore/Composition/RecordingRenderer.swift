import CoreImage
import CoreGraphics
import Foundation

/// Shared source-time evaluation for composition, live preview and export.
public enum RecordingRenderer {
    public static func render(_ source: CIImage?, clip: Clip, time: Double, size: CGSize) -> CIImage? {
        guard let settings = clip.recording else { return source }
        let t = clip.sourceTime(at: time) + settings.timeOffset
        let p = settings.evaluated(at: t)
        guard p.isVisible(at: t) else { return nil }
        let frame = CGRect(origin: .zero, size: size)
        var image: CIImage?
        if p.role == .cursor {
            image = cursor(p, time: t, size: size)?.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(clip.opacity))])
        }
        else if p.role == .camera, let source {
            let rect = cameraRect(p, size: size)
            var result = source.transformed(by: cameraTransform(p, clip: clip, size: size)).cropped(to: rect)
            if p.shape != .rectangle, let mask = mask(p.shape, rect: rect, frame: frame) {
                result = result.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: frame), kCIInputMaskImageKey: mask])
            }
            image = result
        } else { image = source }
        if p.role != .camera || p.cameraFollowsZoom { image = image?.transformed(by: zoomTransform(p, time: t, size: size)) }
        return image?.cropped(to: frame)
    }
    public static func cameraRect(_ p: RecordingClipPresentation, size: CGSize) -> CGRect {
        let w = size.width * min(1, max(0.03, p.cameraSize)), h = p.shape == .circle ? w : w / max(0.1, p.cameraAspectRatio ?? size.width / size.height)
        let x = min(size.width - w / 2, max(w / 2, p.cameraX * size.width)), y = min(size.height - h / 2, max(h / 2, (1 - p.cameraY) * size.height))
        return CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
    }
    public static func cameraTransform(_ p: RecordingClipPresentation, clip: Clip, size: CGSize) -> CGAffineTransform {
        let ratio = p.cameraAspectRatio ?? p.sourceAspectRatio ?? size.width / size.height
        let content = PreviewGeometry.placement(source: CGSize(width: max(0.1, ratio) * 1000, height: 1000), canvas: size, transform: clip.transform)
        let target = cameraRect(p, size: size)
        let scale = max(target.width / max(1, content.width), target.height / max(1, content.height))
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: target.midX - content.midX * scale, ty: target.midY - content.midY * scale)
    }
    public static func zoomTransform(_ p: RecordingClipPresentation, time: Double, size: CGSize) -> CGAffineTransform {
        let z = p.zoom(at: time)
        guard z.scale > 1 else { return .identity }
        let rect = pictureRect(p, size: size)
        let x = min(size.width - size.width / (2 * z.scale), max(size.width / (2 * z.scale), rect.minX + z.x * rect.width))
        let y = min(size.height - size.height / (2 * z.scale), max(size.height / (2 * z.scale), rect.minY + (1 - z.y) * rect.height))
        return CGAffineTransform(a: z.scale, b: 0, c: 0, d: z.scale, tx: size.width / 2 - x * z.scale, ty: size.height / 2 - y * z.scale)
    }
    public static func pictureRect(_ p: RecordingClipPresentation, size: CGSize) -> CGRect {
        let ratio = p.sourceAspectRatio ?? size.width / max(1, size.height)
        return PreviewGeometry.placement(source: CGSize(width: max(0.01, ratio) * 1000, height: 1000), canvas: size, transform: p.screenTransform ?? .identity)
    }
    private static func context(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    private static func mask(_ shape: RecordingClipPresentation.Shape, rect: CGRect, frame: CGRect) -> CIImage? {
        guard let c = context(frame.size) else { return nil }
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        if shape == .circle { c.fillEllipse(in: rect) } else { c.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width * 0.08, cornerHeight: rect.width * 0.08, transform: nil)); c.fillPath() }
        return c.makeImage().map(CIImage.init(cgImage:))
    }
    public static func cursor(_ p: RecordingClipPresentation, time: Double, size: CGSize) -> CIImage? {
        guard let sample = p.pointer(at: time), (0...1).contains(sample.x), (0...1).contains(sample.y), let c = context(size) else { return nil }
        let rect = pictureRect(p, size: size)
        let side = max(8, min(160, size.height * p.cursorSize)), x = rect.minX + sample.x * rect.width, y = rect.minY + (1 - sample.y) * rect.height
        if p.showClicks, let click = p.pointer.last(where: { $0.clicked && $0.time <= time && time - $0.time < 0.4 }) {
            let amount = (time - click.time) / 0.4, r = side * (0.5 + amount)
            c.setStrokeColor(CGColor(red: 0.2, green: 0.7, blue: 1, alpha: 1 - amount)); c.setLineWidth(max(2, side * 0.1))
            c.strokeEllipse(in: CGRect(x: rect.minX + click.x * rect.width - r, y: rect.minY + (1 - click.y) * rect.height - r, width: 2 * r, height: 2 * r))
        }
        c.translateBy(x: x, y: y); c.scaleBy(x: side, y: -side)
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.setStrokeColor(CGColor(gray: 0.05, alpha: 1)); c.setLineWidth(0.07)
        let path = CGMutablePath()
        switch p.cursor {
        case .circle: path.addEllipse(in: CGRect(x: -0.35, y: -0.35, width: 0.7, height: 0.7))
        case .crosshair:
            path.move(to: CGPoint(x: -0.5, y: 0)); path.addLine(to: CGPoint(x: 0.5, y: 0)); path.move(to: CGPoint(x: 0, y: -0.5)); path.addLine(to: CGPoint(x: 0, y: 0.5))
        case .hand:
            path.addRoundedRect(in: CGRect(x: -0.15, y: 0.25, width: 0.7, height: 0.7), cornerWidth: 0.15, cornerHeight: 0.15)
            path.addRoundedRect(in: CGRect(x: 0, y: -0.2, width: 0.18, height: 0.8), cornerWidth: 0.09, cornerHeight: 0.09)
        case .arrow:
            path.move(to: .zero); for point in [CGPoint(x: 0, y: 1), CGPoint(x: 0.25, y: 0.72), CGPoint(x: 0.47, y: 1.13), CGPoint(x: 0.65, y: 1.03), CGPoint(x: 0.42, y: 0.62), CGPoint(x: 0.8, y: 0.6)] { path.addLine(to: point) }; path.closeSubpath()
        }
        c.addPath(path); c.drawPath(using: .fillStroke)
        return c.makeImage().map(CIImage.init(cgImage:))
    }
}
