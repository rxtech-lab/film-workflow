import AppKit
import AVFoundation
import Testing
@testable import RxRemotion

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RX_REMOTION_BENCHMARK"] == "1")) @MainActor
struct BenchmarkTests {
    @Test func measure() async throws {
        let root = URL(fileURLWithPath: "/tmp/rxremotion-benchmark-" + UUID().uuidString)
        try RemotionEngine.scaffold(at: root)
        let frameCount = Int(ProcessInfo.processInfo.environment["RX_REMOTION_BENCHMARK_FRAMES"] ?? "30") ?? 30
        let source = """
        import React from 'react';import {AbsoluteFill,useCurrentFrame,spring,interpolate} from 'remotion';
        export const COMPOSITION_WIDTH=1920,COMPOSITION_HEIGHT=1080,COMPOSITION_FPS=30,COMPOSITION_DURATION_IN_FRAMES=\(frameCount);
        export function MyComposition(){let f=useCurrentFrame();let s=spring({frame:f,fps:30,config:{damping:14}});return <AbsoluteFill style={{fontFamily:'Arial',color:'white',background:'#15243a',justifyContent:'center',padding:120}}><div style={{fontSize:112,fontWeight:700,transform:`translateX(${s*80}px)`}}>RxRemotion</div><div style={{fontSize:44,marginTop:36}}>Native WebKit · frame {f}</div><div style={{height:30,width:interpolate(f,[0,29],[20,1400]),background:'#42c9ad',marginTop:60}}/><svg width={180} height={180}><circle cx={90} cy={90} r={64} fill='#ef7851'/></svg></AbsoluteFill>}
        """
        try source.write(to: root.appendingPathComponent("src/Composition.tsx"), atomically: true, encoding: .utf8)
        let engine = RemotionEngine(); defer { engine.closeAll() }
        var metrics: [String: Double] = [:]
        var start = Date()
        let prepared = try await engine.prepare(projectURL: root)
        metrics["coldCompilationSeconds"] = Date().timeIntervalSince(start)
        start = Date(); _ = try await engine.prepare(projectURL: root)
        metrics["warmPrepareSeconds"] = Date().timeIntervalSince(start)
        start = Date(); let session = try await engine.makePreviewSession(project: prepared)
        metrics["previewAfterCompilationSeconds"] = Date().timeIntervalSince(start)
        start = Date(); try await session.seek(to: min(15, frameCount - 1))
        metrics["seekCommandSeconds"] = Date().timeIntervalSince(start)
        session.dispose()
        start = Date(); try await engine.renderStill(project: prepared, frame: min(15, frameCount - 1), to: root.appendingPathComponent("native.png"))
        metrics["png1080pSeconds"] = Date().timeIntervalSince(start)
        let alpha = ProcessInfo.processInfo.environment["RX_REMOTION_BENCHMARK_ALPHA"] == "1"
        let concurrency = Int(ProcessInfo.processInfo.environment["RX_REMOTION_BENCHMARK_CONCURRENCY"] ?? "")
        let captureScale = Double(ProcessInfo.processInfo.environment["RX_REMOTION_BENCHMARK_CAPTURE_SCALE"] ?? "")
        let movie = root.appendingPathComponent(alpha ? "native.mov" : "native.mp4")
        var largestMainActorGap = 0.0
        let heartbeat = Task { @MainActor in
            var previous = Date()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                let now = Date(); largestMainActorGap = max(largestMainActorGap, now.timeIntervalSince(previous)); previous = now
            }
        }
        defer { heartbeat.cancel() }
        await Task.yield()
        start = Date(); try await engine.renderMovie(project: prepared, to: movie, settings: .init(codec: alpha ? .proRes4444 : .h264, concurrency: concurrency, captureScale: captureScale))
        metrics["largestMainActorGapSeconds"] = largestMainActorGap
        metrics["alpha"] = alpha ? 1 : 0
        metrics["captureScale"] = captureScale ?? 1
        metrics["requestedConcurrency"] = Double(concurrency ?? 0)
        metrics["movieSeconds"] = Date().timeIntervalSince(start)
        metrics["frameCount"] = Double(frameCount)
        metrics["exportFramesPerSecond"] = Double(frameCount) / metrics["movieSeconds"]!
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        metrics["hostPeakResidentBytesExcludingWebKitServices"] = Double(usage.ru_maxrss)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metrics).write(to: root.appendingPathComponent("native-metrics.json"))
        print("RX_REMOTION_BENCHMARK=\(root.path)")
        print(String(data: try encoder.encode(metrics), encoding: .utf8)!)
        let asset = AVURLAsset(url: movie)
        #expect(abs(try await asset.load(.duration).seconds - Double(frameCount) / 30) < 0.001)
    }
}
