@preconcurrency import AVFoundation
import CoreAudio
import Foundation

nonisolated final class RecordingAudioTap: @unchecked Sendable {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private let writer: RecordingMediaWriter
    private var format: CMAudioFormatDescription?
    private let queue = DispatchQueue(label: "rx.recording.audio-tap")
    init(processes: [AudioObjectID], excluding: Bool, writer: RecordingMediaWriter) throws {
        self.writer = writer
        let description = excluding ? CATapDescription(stereoGlobalTapButExcludeProcesses: processes) : CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "RxFilmStudio Recording"; description.isPrivate = true; description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap))
        do {
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var asbd = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd))
            try check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format))
            let spec: [String: Any] = [kAudioAggregateDeviceNameKey: "RxFilmStudio capture", kAudioAggregateDeviceUIDKey: UUID().uuidString, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
            try check(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &device))
            let bytesPerFrame = max(1, asbd.mBytesPerFrame), sampleRate = asbd.mSampleRate
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, time, _, _ in
                guard let self, let format = self.format else { return }
                let frames = Int(input.pointee.mBuffers.mDataByteSize / bytesPerFrame)
                guard frames > 0 else { return }
                var sample: CMSampleBuffer?
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)), presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(time.pointee.mHostTime), decodeTimeStamp: .invalid)
                guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample else { return }
                guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: input) == noErr else { return }
                CMSampleBufferSetDataReady(sample)
                self.writer.append(sample)
            })
            try check(AudioDeviceStart(device, proc))
        } catch { stop(); throw error }
    }
    func stop() {
        if let proc { AudioDeviceStop(device, proc); AudioDeviceDestroyIOProcID(device, proc); self.proc = nil }
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
    deinit { stop() }
    private func check(_ status: OSStatus) throws { if status != noErr { throw RecordingError.message("Audio capture failed (\(status)). Check Screen & System Audio Recording permission.") } }
    static func processes() -> [String: [AudioObjectID]] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [:] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [:] }
        var result: [String: [AudioObjectID]] = [:]
        for id in ids {
            var bundle: CFString = "" as CFString
            address.mSelector = kAudioProcessPropertyBundleID; size = UInt32(MemoryLayout<CFString>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &bundle) == noErr, !(bundle as String).isEmpty { result[bundle as String, default: []].append(id) }
        }
        return result
    }
}
