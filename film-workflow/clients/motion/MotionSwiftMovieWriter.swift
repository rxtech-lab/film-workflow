import AVFoundation
import Accelerate
import CoreVideo
import Foundation

/// Ordered AVFoundation video writer for MotionSwift frames: H.264 for opaque renders
/// or ProRes 4444 with alpha. Shared Metal IOSurface frames are appended without a CPU
/// copy; CPU readbacks (unpremultiplied RGBA) are converted into pooled BGRA buffers.
/// Call only from the pipeline's consumer thread.
final class MotionSwiftMovieWriter {
    enum Codec { case h264, proRes4444 }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Double
    private let width: Int
    private let height: Int
    private let cancellation: CancellationFlag
    private var frames = 0

    init(output: URL, width: Int, height: Int, fps: Double, codec: Codec, cancellation: CancellationFlag) throws {
        if codec == .h264, !width.isMultiple(of: 2) || !height.isMultiple(of: 2) {
            throw MotionSwiftEngine.Failure("H.264 export requires even pixel dimensions")
        }
        try? FileManager.default.removeItem(at: output)
        let fileType: AVFileType = output.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        var settings: [String: Any] = [
            AVVideoCodecKey: codec == .proRes4444 ? AVVideoCodecType.proRes4444 : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ]
        if codec == .h264 {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: max(4_000_000, Int(Double(width * height) * fps * 0.15)),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
            ]
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        guard writer.canAdd(input) else { throw MotionSwiftEngine.Failure("This Mac cannot encode the requested video format") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? MotionSwiftEngine.Failure("Could not start the video encoder")
        }
        writer.startSession(atSourceTime: .zero)
        self.fps = fps
        self.width = width
        self.height = height
        self.cancellation = cancellation
    }

    /// Appends a GPU-completed BGRA frame (MotionSwift shared video frames).
    func append(_ buffer: CVPixelBuffer) throws {
        try waitUntilReady()
        guard adaptor.append(buffer, withPresentationTime: time(frames)) else {
            throw writer.error ?? MotionSwiftEngine.Failure("Could not append an export frame")
        }
        frames += 1
    }

    /// Appends unpremultiplied, tightly packed RGBA8888 pixels.
    func append(rgba: Data) throws {
        guard rgba.count == width * height * 4 else { throw MotionSwiftEngine.Failure("Unexpected frame size") }
        try waitUntilReady()
        guard let pool = adaptor.pixelBufferPool else { throw MotionSwiftEngine.Failure("The encoder did not allocate a frame pool") }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw MotionSwiftEngine.Failure("Cannot allocate an export frame")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        var source = rgba
        let converted = source.withUnsafeMutableBytes { bytes -> Bool in
            var src = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                    rowBytes: width * 4)
            var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddress(buffer), height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
            // Core Video BGRA is premultiplied.
            guard vImagePremultiplyData_RGBA8888(&src, &src, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
            let map: [UInt8] = [2, 1, 0, 3]
            return vImagePermuteChannels_ARGB8888(&src, &dst, map, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard converted else { throw MotionSwiftEngine.Failure("Cannot convert an export frame") }
        guard adaptor.append(buffer, withPresentationTime: time(frames)) else {
            throw writer.error ?? MotionSwiftEngine.Failure("Could not append an export frame")
        }
        frames += 1
    }

    func finish() throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: time(frames))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw writer.error ?? MotionSwiftEngine.Failure("Video encoding failed")
        }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
    }

    private func time(_ frame: Int) -> CMTime {
        CMTime(value: CMTimeValue(frame) * 1000, timescale: CMTimeScale((fps * 1000).rounded()))
    }

    private func waitUntilReady() throws {
        while !input.isReadyForMoreMediaData {
            try cancellation.check()
            guard writer.status == .writing else {
                throw writer.error ?? MotionSwiftEngine.Failure("Video encoder stopped")
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        try cancellation.check()
    }
}
