import AppKit
import AVFoundation
import Testing
@testable import RxRemotion

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RX_REMOTION_INTEGRATION"] == "1")) @MainActor
struct MediaIntegrationTests {
    func project(_ source: String) throws -> URL {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RxRemotionMedia-" + UUID().uuidString)
        try RemotionEngine.scaffold(at: url)
        try source.write(to: url.appendingPathComponent("src/Composition.tsx"), atomically: true, encoding: .utf8)
        return url
    }
    let constants = "export const COMPOSITION_WIDTH=320,COMPOSITION_HEIGHT=180,COMPOSITION_FPS=30,COMPOSITION_DURATION_IN_FRAMES=30;"

    @Test func audioVideoAndReload() async throws {
        let root = try project(constants + "import {AbsoluteFill,useCurrentFrame} from 'remotion'; export function MyComposition(){let f=useCurrentFrame();return <AbsoluteFill style={{backgroundColor:f<15?'red':'blue'}}/>}")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RemotionEngine(); defer { engine.closeAll() }
        let prepared = try await engine.prepare(projectURL: root)
        try await engine.renderMovie(project: prepared, to: root.appendingPathComponent("public/clip.mp4"))
        let source = constants + """
        import React from 'react'; import {AbsoluteFill,Audio,Video,Loop,Sequence,staticFile} from 'remotion';
        export function MyComposition(){return <AbsoluteFill><Sequence from={3} durationInFrames={20}><Video src={staticFile('clip.mp4')} trimBefore={2} playbackRate={0.75} muted/></Sequence><Sequence from={6} durationInFrames={24}><Loop durationInFrames={8} times={3}><Audio src={staticFile('tone.wav')} trimBefore={4} playbackRate={1.5} volume={f=>f<4?0.25:0.5}/></Loop></Sequence></AbsoluteFill>}
        """
        try Self.wav().write(to: root.appendingPathComponent("public/tone.wav"))
        try source.write(to: root.appendingPathComponent("src/Composition.tsx"), atomically: true, encoding: .utf8)
        try await prepared.compileIfNeeded()
        let output = root.appendingPathComponent("media.mp4")
        try await engine.renderMovie(project: prepared, to: output)
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(try await asset.load(.duration).seconds - 1) < 0.001)
        let reader = try AVAssetReader(asset: asset)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let pcm = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32])
        reader.add(pcm); #expect(reader.startReading())
        var energy = 0.0, count = 0, earlyEnergy = 0.0, earlyCount = 0
        while let sample = pcm.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [Float](repeating: 0, count: length / 4)
            _ = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            let channels = max(1, bytes.count / max(1, CMSampleBufferGetNumSamples(sample)))
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for (index, value) in bytes.enumerated() where start + Double(index / channels) / 48000 < 0.15 {
                earlyEnergy += Double(value * value); earlyCount += 1
            }
            energy += bytes.reduce(0) { $0 + Double($1 * $1) }; count += bytes.count
        }
        #expect(earlyCount > 0); #expect(earlyEnergy / Double(max(earlyCount, 1)) < 0.00001)
        #expect(count > 0); #expect(energy / Double(max(count, 1)) > 0.001)
        let image = root.appendingPathComponent("video.png")
        try await engine.renderStill(project: prepared, frame: 10, to: image)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: image)))
        #expect(try #require(bitmap.colorAt(x: 160, y: 90)).redComponent > 0.8)
    }

    @Test func localModulesCSSAndCancellation() async throws {
        let root = try project(constants + "import React from 'react';import './style.css';import {color} from './local';import {useCurrentFrame} from 'remotion';export function MyComposition(){return <div data-frame={useCurrentFrame()} className='card' style={{background:color}}/>}")
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const color: string='lime'".write(to: root.appendingPathComponent("src/local.ts"), atomically: true, encoding: .utf8)
        try ".card{width:100px;height:100px;border-radius:8px}".write(to: root.appendingPathComponent("src/style.css"), atomically: true, encoding: .utf8)
        let engine = RemotionEngine(); defer { engine.closeAll() }
        let prepared = try await engine.prepare(projectURL: root)
        let session1 = try await engine.makePreviewSession(project: prepared)
        let session2 = try await engine.makePreviewSession(project: prepared)
        defer { session1.dispose(); session2.dispose() }
        try await session1.seek(to: 4); try await session2.seek(to: 12)
        #expect(session1.webView !== session2.webView)
        for _ in 0..<20 {
            if try await session1.webView.evaluateJavaScript("document.querySelector('.card')?.dataset.frame") as? String == "4" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await session1.webView.evaluateJavaScript("document.querySelector('.card')?.dataset.frame") as? String == "4")
        #expect(try await session2.webView.evaluateJavaScript("document.querySelector('.card')?.dataset.frame") as? String == "12")
        let output = root.appendingPathComponent("cancelled.mp4")
        let task = Task { try await engine.renderMovie(project: prepared, to: output) }
        task.cancel()
        do { try await task.value; Issue.record("Cancelled export completed") } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let image = root.appendingPathComponent("css.png")
        try await engine.renderStill(project: prepared, frame: 0, to: image)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: image)))
        #expect(try #require(bitmap.colorAt(x: 30, y: 30)).greenComponent > 0.9)
        try "import fs from 'node:fs'; export function MyComposition(){return fs.readFileSync('/tmp/a')}".write(to: root.appendingPathComponent("src/Composition.tsx"), atomically: true, encoding: .utf8)
        do { try await prepared.compileIfNeeded(); Issue.record("Node import compiled") } catch { #expect(error.localizedDescription.contains("node:fs")) }
    }
    @Test func cssAssetsAndConcurrentPreparation() async throws {
        let root = try project(constants + "import './style.css';import 'leaflet/dist/leaflet.css';export function MyComposition(){return <div className='asset'/>}")
        defer { try? FileManager.default.removeItem(at: root) }
        try "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'><rect width='100' height='100' fill='lime'/></svg>".write(to: root.appendingPathComponent("public/tile.svg"), atomically: true, encoding: .utf8)
        try ".asset{width:100px;height:100px;background-image:url('../public/tile.svg')}".write(to: root.appendingPathComponent("src/style.css"), atomically: true, encoding: .utf8)
        let engine = RemotionEngine(); defer { engine.closeAll() }
        let first = Task { try await engine.prepare(projectURL: root) }
        let second = Task { try await engine.prepare(projectURL: root) }
        let prepared = try await first.value
        #expect(try await second.value === prepared)
        let output = root.appendingPathComponent("assets.png")
        try await engine.renderStill(project: prepared, frame: 0, to: output)
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        #expect(try #require(image.colorAt(x: 20, y: 20)).greenComponent > 0.9)
    }
    @Test func audioGainAndNativeLoop() async throws {
        let root = try project(constants)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.wav().write(to: root.appendingPathComponent("public/tone.wav"))
        let engine = RemotionEngine(); defer { engine.closeAll() }
        var energies: [Double] = []
        for gain in [0.5, 2.0] {
            let source = constants + "import {Audio,staticFile} from 'remotion';export function MyComposition(){return <Audio loop src={staticFile('tone.wav')} volume={\(gain)}/>;}"
            try source.write(to: root.appendingPathComponent("src/Composition.tsx"), atomically: true, encoding: .utf8)
            let prepared = try await engine.prepare(projectURL: root)
            let output = root.appendingPathComponent("gain-\(gain).mov")
            try await engine.renderMovie(project: prepared, to: output, settings: .init(codec: .proRes4444))
            let asset = AVURLAsset(url: output)
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let reader = try AVAssetReader(asset: asset)
            let pcm = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32])
            reader.add(pcm); #expect(reader.startReading())
            var energy = 0.0, count = 0
            while let sample = pcm.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
                let length = CMBlockBufferGetDataLength(block)
                var bytes = [Float](repeating: 0, count: length / 4)
                _ = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                energy += bytes.reduce(0) { $0 + Double($1 * $1) }; count += bytes.count
            }
            energies.append(energy / Double(max(1, count)))
        }
        #expect(energies[0] > 0)
        #expect(abs(energies[1] / energies[0] - 16) < 0.5)
    }
    @Test func cancellationDuringCapturePreservesDestination() async throws {
        let root = try project(constants + "import {AbsoluteFill} from 'remotion';export function MyComposition(){return <AbsoluteFill style={{background:'red'}}/>}")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RemotionEngine(); defer { engine.closeAll() }
        let prepared = try await engine.prepare(projectURL: root)
        let output = root.appendingPathComponent("existing.mp4")
        let original = Data("existing output".utf8)
        try original.write(to: output)
        var export: Task<Void, Error>?
        export = Task { @MainActor in
            try await engine.renderMovie(project: prepared, to: output) { progress in
                if progress.stage == .rendering { export?.cancel() }
            }
        }
        do { try await export!.value; Issue.record("A cancelled capture completed") }
        catch is CancellationError {} catch { Issue.record("Wrong cancellation result: \(error)") }
        #expect(try Data(contentsOf: output) == original)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!remaining.contains { $0.hasPrefix(".rxremotion-") })
    }
    static func wav() -> Data {
        let rate = 48000, frames = 96000
        var data = Data()
        func string(_ s: String) { data.append(contentsOf: s.utf8) }
        func int<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        string("RIFF"); int(UInt32(36 + frames * 2)); string("WAVEfmt "); int(UInt32(16)); int(UInt16(1)); int(UInt16(1))
        int(UInt32(rate)); int(UInt32(rate * 2)); int(UInt16(2)); int(UInt16(16)); string("data"); int(UInt32(frames * 2))
        for index in 0..<frames { int(Int16(sin(Double(index) * 440 * 2 * .pi / Double(rate)) * 16000)) }
        return data
    }
}
