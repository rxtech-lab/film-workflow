import CoreGraphics
import Foundation
import RxRemotionPixels

/// Snapshot acquisition stays on MainActor; all full-frame allocation, scaling and
/// matte reconstruction run on the concurrent executor, including Debug builds.
enum CapturePixels {
    @concurrent static func image(black: CGImage, white: CGImage?, width: Int, height: Int) async throws -> CGImage {
        try Task.checkCancellation()
        var bytes = try pixels(black, width: width, height: height)
        if let white {
            let light = try pixels(white, width: width, height: height)
            try bytes.withUnsafeMutableBufferPointer { dark in
                try light.withUnsafeBufferPointer { light in
                    for row in stride(from: 0, to: height, by: 64) {
                        try Task.checkCancellation()
                        let offset = row * width * 4
                        RxRemotionRecoverAlpha(dark.baseAddress! + offset, light.baseAddress! + offset,
                                               min(64, height - row) * width)
                    }
                }
            }
        }
        try Task.checkCancellation()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw RemotionError.rendering("Could not construct the captured frame")
        }
        return image
    }

    private static func pixels(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { data in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw RemotionError.rendering("Could not allocate a captured frame")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }
}
