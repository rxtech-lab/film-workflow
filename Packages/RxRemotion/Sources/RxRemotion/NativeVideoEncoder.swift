import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// A single ordered encoder, isolated from AppKit/WebKit and the UI executor.
actor NativeVideoEncoder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let c: RemotionComposition

    @concurrent static func make(output: URL, composition: RemotionComposition, codec: RemotionRenderSettings.Codec) async throws -> NativeVideoEncoder {
        try NativeVideoEncoder(output: output, composition: composition, codec: codec)
    }
    private init(output: URL, composition c: RemotionComposition, codec: RemotionRenderSettings.Codec) throws {
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec == .proRes4444 ? AVVideoCodecType.proRes4444 : AVVideoCodecType.h264,
            AVVideoWidthKey: c.width, AVVideoHeightKey: c.height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                       AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                       AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: c.width, kCVPixelBufferHeightKey as String: c.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw RemotionError.unsupported("This Mac cannot encode the requested video format") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RemotionError.rendering("Could not start the video encoder") }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer; self.input = input; self.adaptor = adaptor; self.c = c
    }
    func append(_ image: CGImage, frame: Int) async throws {
        try Task.checkCancellation()
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? RemotionError.rendering("Video encoder stopped") }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard let pool = adaptor.pixelBufferPool else { throw RemotionError.rendering("The encoder did not allocate a frame pool") }
        var pixel: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary
        while pixel == nil {
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &pixel)
            if status == kCVReturnWouldExceedAllocationThreshold {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? RemotionError.rendering("Video encoder stopped") }
                try await Task.sleep(for: .milliseconds(2))
            } else if status != kCVReturnSuccess { throw RemotionError.rendering("Cannot allocate an export frame") }
        }
        guard let pixel else { throw RemotionError.rendering("Missing export frame") }
        CVPixelBufferLockBaseAddress(pixel, [])
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: c.width, height: c.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmap) else {
            CVPixelBufferUnlockBaseAddress(pixel, []); throw RemotionError.rendering("Cannot draw an export frame")
        }
        context.clear(CGRect(x: 0, y: 0, width: c.width, height: c.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: c.width, height: c.height))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        guard adaptor.append(pixel, withPresentationTime: CMTime(seconds: Double(frame) / c.fps, preferredTimescale: 60000)) else {
            throw writer.error ?? RemotionError.rendering("Could not append an export frame")
        }
    }
    func finish() async throws {
        try Task.checkCancellation()
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: c.duration, preferredTimescale: 60000))
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? RemotionError.rendering("Video encoding failed") }
    }
    func cancel() { writer.cancelWriting() }
}
