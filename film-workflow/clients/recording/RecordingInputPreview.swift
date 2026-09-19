import AppKit
@preconcurrency import AVFoundation
import SwiftUI

@MainActor @Observable final class RecordingInputPreviewStore {
    static let shared = RecordingInputPreviewStore()
    var previews: [String: RecordingPreviewInput] = [:]
    var error: String?
    func start(id: String, video: Bool) async {
        guard previews[id] == nil, !RecordingSession.shared.isActive else { return }
        do {
            guard await AVCaptureDevice.requestAccess(for: video ? .video : .audio) else { throw RecordingError.message("Allow access to preview this input.") }
            let input = try RecordingPreviewInput(id: id, video: video)
            previews[id] = input; await input.start()
        } catch { self.error = error.localizedDescription }
    }
    func stop(id: String) async { let input = previews.removeValue(forKey: id); await input?.stop() }
    func stopAll() async { let inputs = Array(previews.values); previews = [:]; for input in inputs { await input.stop() } }
}

@MainActor @Observable final class RecordingPreviewInput {
    let session: AVCaptureSession
    var level: Double = 0
    private let meter: RecordingPreviewMeter
    init(id: String, video: Bool) throws {
        session = AVCaptureSession(); meter = RecordingPreviewMeter()
        guard let device = AVCaptureDevice(uniqueID: id) else { throw RecordingError.message("Input disconnected.") }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecordingError.message("Input is unavailable.") }; session.addInput(input)
        if !video {
            let output = AVCaptureAudioDataOutput(); output.setSampleBufferDelegate(meter, queue: DispatchQueue(label: "rx.recording.preview-meter"))
            guard session.canAddOutput(output) else { throw RecordingError.message("Cannot preview this microphone.") }; session.addOutput(output)
        }
        meter.onLevel = { [weak self] level in Task { @MainActor in self?.level = level } }
    }
    func start() async { let session = session; await Task.detached { session.startRunning() }.value }
    func stop() async { let session = session; await Task.detached { session.stopRunning() }.value }
}
nonisolated private final class RecordingPreviewMeter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onLevel: (@Sendable (Double) -> Void)?
    private var last = 0.0
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = sampleBuffer.presentationTimeStamp.seconds; guard time - last > 0.08 else { return }; last = time
        onLevel?(RecordingAudioMeter.level(sampleBuffer))
    }
}
nonisolated enum RecordingAudioMeter {
    static func level(_ buffer: CMSampleBuffer) -> Double {
        guard let format = buffer.formatDescription, let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = CMSampleBufferGetDataBuffer(buffer) else { return 0 }
        var pointer: UnsafeMutablePointer<Int8>?, length = 0
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { return 0 }
        var peak = 0.0
        if stream.mFormatFlags & kAudioFormatFlagIsFloat != 0, stream.mBitsPerChannel == 32 {
            let samples = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
            for index in stride(from: 0, to: length / 4, by: 4) { peak = max(peak, Double(abs(samples[index]))) }
        } else if stream.mBitsPerChannel == 16 {
            let samples = UnsafeRawPointer(pointer).assumingMemoryBound(to: Int16.self)
            for index in stride(from: 0, to: length / 2, by: 4) { peak = max(peak, abs(Double(samples[index])) / 32768) }
        }
        return min(1, max(0, (20 * log10(max(0.0001, peak)) + 60) / 60))
    }
}

struct RecordingInputPreview: View {
    let id: String
    let video: Bool
    @State private var store = RecordingInputPreviewStore.shared
    @State private var session = RecordingSession.shared
    var body: some View {
        Group {
            if let capture = session.previewSession(id: id), video { RecordingCameraSurface(session: capture).frame(height: 110) }
            else if let input = store.previews[id] {
                if video { RecordingCameraSurface(session: input.session).frame(height: 110) }
                else { ProgressView(value: input.level).tint(input.level > 0.9 ? .red : .green) }
            } else if !video, session.isActive { ProgressView(value: session.audioLevels[id] ?? 0).tint(.green) }
            else if !session.isActive { Button("Preview", systemImage: video ? "video" : "waveform") { Task { await store.start(id: id, video: video) } } }
        }.onDisappear { Task { await store.stop(id: id) } }
    }
}
private struct RecordingCameraSurface: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspect
        view.layer = layer; return view
    }
    func updateNSView(_ view: NSView, context: Context) { (view.layer as? AVCaptureVideoPreviewLayer)?.session = session }
}

struct RecordingWindowSourcePreview: View {
    let id: String
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 130) } }
            .task(id: id) { image = nil; if let number = UInt32(id), let data = try? await RecordingScreenshotService.capture(windowID: number).first?.png { image = NSImage(data: data) } }
    }
}
