import AppKit
import AVFoundation
import Testing
@testable import RxRemotion

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RX_REMOTION_INTEGRATION"] == "1")) @MainActor
struct ParallelRenderingTests {
    @Test func serialAndParallelPreserveStateFramesAndAudio() async throws {
        let source = """
        import React,{useEffect,useRef} from 'react';
        import {Audio,Sequence,Loop,staticFile,useCurrentFrame} from 'remotion';
        export const COMPOSITION_WIDTH=160,COMPOSITION_HEIGHT=90,COMPOSITION_FPS=30,COMPOSITION_DURATION_IN_FRAMES=13;
        export function MyComposition(){const f=useCurrentFrame(),canvas=useRef(null),state=useRef(0);
          useEffect(()=>{state.current+=f+1;const c=canvas.current.getContext('2d');c.clearRect(0,0,160,90);
            c.fillStyle='rgba(40,220,80,0.5)';c.fillRect(state.current%120,10,30,40)},[f]);
          return <><canvas ref={canvas} width={160} height={90}/>
            <Sequence from={2} durationInFrames={10}><Loop durationInFrames={4}>
              <Audio src={staticFile('tone.wav')} trimBefore={3} playbackRate={1} volume={f=>0.2+f*0.1}/>
            </Loop></Sequence></>}
        """
        let root = try MediaIntegrationTests().project(source)
        defer { try? FileManager.default.removeItem(at: root) }
        try MediaIntegrationTests.wav().write(to: root.appendingPathComponent("public/tone.wav"))
        let engine = RemotionEngine(); defer { engine.closeAll() }
        let project = try await engine.prepare(projectURL: root)
        var reference: DecodedMovie?
        for count in [1, 1, 2, 4] {
            // Keep exports outside the input tree so each worker count uses identical inputs.
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            defer { try? FileManager.default.removeItem(at: output) }
            var progress: [Double] = []
            try await engine.renderMovie(project: project, to: output, settings: .init(codec: .proRes4444, concurrency: count)) {
                if $0.stage == .rendering, let fraction = $0.fraction { progress.append(fraction) }
            }
            let decoded = try await Self.decode(output)
            #expect(decoded.frames.count == 13)
            #expect(progress.count == 13); #expect(progress == progress.sorted()); #expect(progress.last == 1)
            #expect(decoded.audio.count >= 12 * 1600 * 4)
            #expect(decoded.audio.count <= 13 * 1600 * 4)
            if let reference {
                let sameFrames = decoded.frames == reference.frames
                #expect(sameFrames, "Stateful canvas and alpha must match serial rendering at every frame")
                let error = Self.audioError(decoded.audio, reference.audio)
                // PCM conversion may dither the least-significant bit. Compare
                // the waveform numerically, including implicit trailing silence.
                #expect(error < 2, "Worker boundaries changed the waveform (RMS error \(error) PCM units)")
            } else { reference = decoded }
        }
    }

    @Test func transparentExportKeepsMainActorResponsive() async throws {
        let root = try MediaIntegrationTests().project("""
        import {useCurrentFrame} from 'remotion';
        export const COMPOSITION_WIDTH=1920,COMPOSITION_HEIGHT=1080,COMPOSITION_FPS=30,COMPOSITION_DURATION_IN_FRAMES=8;
        export function MyComposition(){return <div style={{width:800,height:800,opacity:0.5,background:'red',transform:`translateX(${useCurrentFrame()}px)`}}/>}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RemotionEngine(); defer { engine.closeAll() }
        let project = try await engine.prepare(projectURL: root)
        var maxGap = 0.0, ticks = 0
        let heartbeat = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                let now = ContinuousClock.now
                let gap = previous.duration(to: now).components
                maxGap = max(maxGap, Double(gap.seconds) + Double(gap.attoseconds) / 1e18)
                previous = now; ticks += 1
            }
        }
        defer { heartbeat.cancel() }
        await Task.yield()
        try await engine.renderMovie(project: project, to: root.appendingPathComponent("responsive.mov"),
                                     settings: .init(codec: .proRes4444, concurrency: 2))
        #expect(ticks >= 5)
        // A generous regression bound for loaded CI hosts. Before the fix this
        // fixture blocked MainActor for ~1.8 seconds per 1080p frame in Debug.
        #expect(maxGap < 0.5, "MainActor was stalled for \(maxGap) seconds")
    }

    private static func audioError(_ a: Data, _ b: Data) -> Double {
        let left = a.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let right = b.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let count = max(left.count, right.count)
        var energy = 0.0
        for index in 0..<count {
            let delta = Double(index < left.count ? left[index] : 0) - Double(index < right.count ? right[index] : 0)
            energy += delta * delta
        }
        return sqrt(energy / Double(max(1, count)))
    }

    private struct DecodedMovie: Sendable {
        var frames: [Data]
        var audio: Data
    }
    @concurrent private static func decode(_ url: URL) async throws -> DecodedMovie {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let pictures = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let pcm = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        reader.add(pictures); reader.add(pcm)
        #expect(reader.startReading())
        var result = DecodedMovie(frames: [], audio: Data())
        while let sample = pictures.copyNextSampleBuffer(), let pixel = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            var frame = Data()
            for row in 0..<CVPixelBufferGetHeight(pixel) {
                frame.append(CVPixelBufferGetBaseAddress(pixel)!.advanced(by: row * CVPixelBufferGetBytesPerRow(pixel)).assumingMemoryBound(to: UInt8.self), count: CVPixelBufferGetWidth(pixel) * 4)
            }
            result.frames.append(frame)
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        }
        while let sample = pcm.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var bytes = Data(count: length)
            _ = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            result.audio.append(bytes)
        }
        #expect(reader.status == .completed)
        return result
    }
}
