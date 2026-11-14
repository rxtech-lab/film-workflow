import AppKit
import Testing
@testable import RxRemotion

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RX_REMOTION_INTEGRATION"] == "1")) @MainActor
struct StillSessionTests {
    @Test func sharedSessionMatchesFreshStatefulRendersAndReusesProgress() async throws {
        let root = try MediaIntegrationTests().project("""
        import React,{useEffect,useRef} from 'react';
        import {useCurrentFrame} from 'remotion';
        export const COMPOSITION_WIDTH=160,COMPOSITION_HEIGHT=90,COMPOSITION_FPS=30,COMPOSITION_DURATION_IN_FRAMES=12;
        export function MyComposition(){const f=useCurrentFrame(),canvas=useRef(null),state=useRef(0);
          useEffect(()=>{state.current+=f+1;const c=canvas.current.getContext('2d');c.clearRect(0,0,160,90);
            c.fillStyle='rgba(40,220,80,0.5)';c.fillRect(state.current%120,10,30,40)},[f]);
          return <canvas ref={canvas} width={160} height={90}/>}
        """)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: output) }
        let engine = RemotionEngine()
        let project = try await engine.prepare(projectURL: root)
        let session = try await engine.makeStillSession(project: project)
        do {
            for (index, frame) in [3, 7, 7, 2].enumerated() {
                let shared = output.appendingPathComponent("shared-\(index).png")
                let fresh = output.appendingPathComponent("fresh-\(index).png")
                try await session.render(frame: frame, to: shared)
                try await engine.renderStill(project: project, frame: frame, to: fresh)
                #expect(try pixels(shared) == pixels(fresh), "Reusing a renderer changed stateful frame \(frame)")
            }
            // Fresh exports advance 23 times for these requests. Reuse advances
            // only 11 times, including a deterministic restart for the backward seek.
            #expect(session.advancedFrameCount == 11)
            await session.close()
            do {
                try await session.render(frame: 0, to: output.appendingPathComponent("closed.png"))
                Issue.record("A closed still session accepted work")
            } catch RemotionError.disposed {}
        } catch {
            await session.close(); engine.closeAll(); throw error
        }
        engine.closeAll()
    }

    @Test func cancellationAllowsNextRequestToRestart() async throws {
        let root = try MediaIntegrationTests().project("""
        import React,{useEffect} from 'react';
        import {delayRender,useCurrentFrame} from 'remotion';
        export const COMPOSITION_WIDTH=160,COMPOSITION_HEIGHT=90,COMPOSITION_FPS=30,COMPOSITION_DURATION_IN_FRAMES=12;
        export function MyComposition(){const f=useCurrentFrame();useEffect(()=>{if(f>0)delayRender('stall')},[f]);
          return <div style={{width:160,height:90,background:'red'}}/>}
        """)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: output) }
        let engine = RemotionEngine()
        defer { engine.closeAll() }
        let project = try await engine.prepare(projectURL: root)
        let session = try await engine.makeStillSession(project: project)
        do {
            let render = Task { try await session.render(frame: 2, to: output) }
            let canceller = Task {
                try? await Task.sleep(for: .milliseconds(250))
                render.cancel()
            }
            defer { canceller.cancel() }
            do { try await render.value; Issue.record("Cancelled thumbnail completed") }
            catch is CancellationError {}
            try await session.render(frame: 0, to: output)
            let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
            #expect(try #require(bitmap.colorAt(x: 80, y: 45)).redComponent > 0.9)
            await session.close()
        } catch { await session.close(); throw error }
    }

    private func pixels(_ url: URL) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        let bytes = try #require(bitmap.bitmapData)
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
