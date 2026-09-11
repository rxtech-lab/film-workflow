import AVFoundation
import Foundation

/// Reverses PCM frames in bounded chunks, preserving channel order. One cached
/// file per source lets speed, cuts and trims reuse it during playback/export.
actor ReversedAudioCache {
    static let shared = ReversedAudioCache()

    private struct Key: Hashable {
        let url: URL
        let modified: Date?
        let size: Int?
    }
    private var files: [Key: URL] = [:]
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RxVideoEditor-reverse-\(UUID())", isDirectory: true)

    deinit { try? FileManager.default.removeItem(at: directory) }

    func file(for url: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = Key(url: url, modified: values.contentModificationDate, size: values.fileSize)
        if let cached = files[key], FileManager.default.fileExists(atPath: cached.path) { return cached }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("\(UUID()).caf")
        do {
            try Self.render(url, to: output)
            files[key] = output
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func render(_ url: URL, to output: URL) throws {
        let source = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = source.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536),
              let channels = buffer.floatChannelData else { throw TimelineEditError.invalidDuration }
        let destination = try AVAudioFile(forWriting: output, settings: format.settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false)
        var end = source.length
        while end > 0 {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(end, AVAudioFramePosition(buffer.frameCapacity)))
            let start = end - AVAudioFramePosition(count)
            source.framePosition = start
            try source.read(into: buffer, frameCount: count)
            guard buffer.frameLength == count else { throw TimelineEditError.invalidDuration }
            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                for index in 0..<(Int(count) / 2) {
                    let opposite = Int(count) - index - 1
                    let sample = samples[index]
                    samples[index] = samples[opposite]
                    samples[opposite] = sample
                }
            }
            try destination.write(from: buffer)
            end = start
        }
    }
}
