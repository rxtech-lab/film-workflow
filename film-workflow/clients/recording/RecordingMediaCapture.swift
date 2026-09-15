@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// The same host-clock mapping is used by screen, device, audio and event producers.
nonisolated final class RecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    private var pauseStart: Double?
    private var pausedDuration: Double = 0
    func reset() { lock.lock(); defer { lock.unlock() }; origin = hostNow; pauseStart = nil; pausedDuration = 0 }
    private var hostNow: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    var elapsed: Double { lock.lock(); defer { lock.unlock() }; return max(0, (pauseStart ?? hostNow) - origin - pausedDuration) }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return pauseStart != nil }
    func pause() { lock.lock(); defer { lock.unlock() }; if pauseStart == nil { pauseStart = hostNow } }
    func resume() { lock.lock(); defer { lock.unlock() }; if let start = pauseStart { pausedDuration += hostNow - start; pauseStart = nil } }
    func time(for sample: CMTime, clock: CMClock? = nil) -> Double? {
        let host = clock.map { CMSyncConvertTime(sample, from: $0, to: CMClockGetHostTimeClock()) } ?? sample
        lock.lock(); defer { lock.unlock() }
        guard pauseStart == nil else { return nil }
        let value = host.seconds - origin - pausedDuration
        return value.isFinite && value >= 0 ? value : nil
    }
}

nonisolated final class RecordingMediaWriter: @unchecked Sendable {
    let url: URL
    let isVideo: Bool
    let clock: RecordingClock
    private let queue = DispatchQueue(label: "rx.recording.writer")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstTime: Double?
    private var lastTime: Double = 0
    private var lastPresentationTime: Double = -1
    private var pixelWidth = 0, pixelHeight = 0
    private var error: String?
    private var finished = false
    private var accepting = true
    private var lastVideoBuffer: CMSampleBuffer?
    private var heartbeat: DispatchSourceTimer?
    var onLevel: (@Sendable (Double) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    var nominalFrameDuration: Double = 1.0 / 60
    private var lastMeter = 0.0
    init(url: URL, video: Bool, clock: RecordingClock) { self.url = url; self.isVideo = video; self.clock = clock }
    func append(_ buffer: CMSampleBuffer, sourceClock: CMClock? = nil) {
        guard CMSampleBufferDataIsReady(buffer), let time = clock.time(for: buffer.presentationTimeStamp, clock: sourceClock) else { return }
        queue.async { [self] in
            guard accepting, !finished, error == nil, time > lastPresentationTime, let format = CMSampleBufferGetFormatDescription(buffer) else { return }
            do {
                if !isVideo, time - lastMeter > 0.08 { lastMeter = time; onLevel?(RecordingAudioMeter.level(buffer)) }
                if writer == nil {
                    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                    writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
                    let settings: [String: Any]
                    if isVideo {
                        let size = CMVideoFormatDescriptionGetDimensions(format); pixelWidth = Int(size.width); pixelHeight = Int(size.height)
                        settings = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: pixelWidth, AVVideoHeightKey: pixelHeight]
                    } else {
                        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }
                        settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: asbd.mChannelsPerFrame, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
                    }
                    let input = AVAssetWriterInput(mediaType: isVideo ? .video : .audio, outputSettings: settings, sourceFormatHint: format)
                    input.expectsMediaDataInRealTime = true
                    guard writer.canAdd(input) else { throw RecordingError.message("This input format cannot be recorded.") }
                    writer.add(input)
                    guard writer.startWriting() else { throw writer.error ?? RecordingError.message("Could not start recording writer.") }
                    writer.startSession(atSourceTime: .zero)
                    self.writer = writer; self.input = input; firstTime = time
                    if isVideo {
                        let timer = DispatchSource.makeTimerSource(queue: queue)
                        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
                        timer.setEventHandler { [weak self] in
                            guard let self, !clock.isPaused, clock.elapsed - lastTime >= 0.4 else { return }
                            appendHeldFrame(at: clock.elapsed)
                        }
                        heartbeat = timer; timer.resume()
                    }
                }
                guard let input, input.isReadyForMoreMediaData, let firstTime else { return }
                var count = 0
                CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
                var timings = Array(repeating: CMSampleTimingInfo(), count: max(1, count))
                CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: timings.count, arrayToFill: &timings, entriesNeededOut: &count)
                let shift = CMTime(seconds: time - firstTime, preferredTimescale: 1_000_000) - buffer.presentationTimeStamp
                for index in timings.indices { timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + shift; timings[index].decodeTimeStamp = .invalid }
                var copy: CMSampleBuffer?
                guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer, sampleTimingEntryCount: timings.count, sampleTimingArray: &timings, sampleBufferOut: &copy) == noErr, let copy else { return }
                guard input.append(copy) else { throw writer?.error ?? RecordingError.message("Recording input failed.") }
                lastPresentationTime = time
                if isVideo { lastVideoBuffer = buffer }
                let duration = buffer.duration.isNumeric && buffer.duration.seconds > 0 ? buffer.duration.seconds : (isVideo ? nominalFrameDuration : 0)
                lastTime = max(lastTime, time + duration)
            } catch { self.error = error.localizedDescription; onFailure?(error.localizedDescription) }
        }
    }
    // ScreenCaptureKit can stop producing complete frames while the picture is
    // static. Hold the last image so media duration and recovery fragments keep
    // following the shared clock, including a static final section.
    private func appendHeldFrame(at time: Double) {
        guard accepting, !finished, error == nil, isVideo, let buffer = lastVideoBuffer,
              let input, input.isReadyForMoreMediaData, let firstTime, time > lastTime else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: nominalFrameDuration, preferredTimescale: 60_000), presentationTimeStamp: CMTime(seconds: time - firstTime, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy else { return }
        if input.append(copy) { lastPresentationTime = time; lastTime = time + nominalFrameDuration }
        else { error = writer?.error?.localizedDescription ?? "Could not preserve a static video frame."; onFailure?(error!) }
    }
    func endSegment() {
        let end = clock.elapsed
        queue.async { [self] in appendHeldFrame(at: max(0, end - nominalFrameDuration)); accepting = false; heartbeat?.cancel(); heartbeat = nil }
    }
    deinit { heartbeat?.cancel() }
    func snapshot() -> (Double, Double, Int, Int)? { queue.sync { firstTime.map { ($0, max(0, lastTime - $0), pixelWidth, pixelHeight) } } }
    func finish() async throws -> (start: Double, duration: Double, width: Int, height: Int)? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                appendHeldFrame(at: max(0, clock.elapsed - nominalFrameDuration)); accepting = false; heartbeat?.cancel(); heartbeat = nil
                finished = true
                guard let writer, let firstTime else { continuation.resume(returning: nil); return }
                input?.markAsFinished()
                writer.finishWriting { [self] in
                    if let error = writer.error ?? self.error.map({ RecordingError.message($0) }) { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: (firstTime, max(0.001, lastTime - firstTime), pixelWidth, pixelHeight)) }
                }
            }
        }
    }
}

nonisolated final class RecordingScreenStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: RecordingMediaWriter
    private(set) var stream: SCStream!
    var onFailure: (@Sendable (String) -> Void)?
    init(filter: SCContentFilter, configuration: SCStreamConfiguration, writer: RecordingMediaWriter) throws {
        self.writer = writer
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "rx.recording.screen"))
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let raw = attachments.first?[.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
        writer.append(sampleBuffer)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?(error.localizedDescription) }
}

nonisolated final class RecordingDeviceCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let deviceID: String
    private let audioWriter: RecordingMediaWriter?
    let writer: RecordingMediaWriter
    var onFailure: (@Sendable (String) -> Void)?
    private var errorObserver: NSObjectProtocol?
    init(deviceID: String, writer: RecordingMediaWriter, fps: Int = 30, audioWriter: RecordingMediaWriter? = nil) throws {
        self.writer = writer; self.deviceID = deviceID; self.audioWriter = audioWriter; super.init()
        errorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            self?.onFailure?((notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "The capture device stopped unexpectedly.")
        }
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw RecordingError.message("The selected device is unavailable.") }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw RecordingError.message("This device is already in use.") }
        session.addInput(input)
        if writer.isVideo {
            let output = AVCaptureVideoDataOutput(); output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "rx.recording.camera"))
            guard session.canAddOutput(output) else { throw RecordingError.message("Cannot capture this camera.") }; session.addOutput(output)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate }) {
                try device.lockForConfiguration(); device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps)); device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(fps)); device.unlockForConfiguration()
            }
        }
        if !writer.isVideo || audioWriter != nil {
            let output = AVCaptureAudioDataOutput(); output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "rx.recording.microphone"))
            guard session.canAddOutput(output) else { throw RecordingError.message("Cannot capture this microphone.") }; session.addOutput(output)
        }
    }
    deinit { if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) } }
    func start() async { await Task.detached { [self] in session.startRunning() }.value }
    func stop() async { await Task.detached { [self] in session.stopRunning() }.value }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { (output is AVCaptureAudioDataOutput ? audioWriter ?? writer : writer).append(sampleBuffer, sourceClock: session.synchronizationClock) }
}
