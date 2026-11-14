import AppKit
import Foundation
import RxAgentSDK
import SwiftData
import Testing
import VideoEditorCore
@testable import film_workflow

@Suite("Native Remotion workflow", .serialized) @MainActor
struct RemotionNativeWorkflowTests {
    @Test("ThreeCanvas draws natively and follows the frame")
    func threeSceneStill() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ThreeStill-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try RemotionRuntime.scaffold(at: root)
        try """
        import {ThreeCanvas} from '@remotion/three';
        import {useCurrentFrame, useVideoConfig} from 'remotion';
        export const COMPOSITION_WIDTH = 320;
        export const COMPOSITION_HEIGHT = 180;
        export const COMPOSITION_FPS = 30;
        export const COMPOSITION_DURATION_IN_FRAMES = 30;
        export function MyComposition() {
          const frame = useCurrentFrame();
          const {width, height} = useVideoConfig();
          return <ThreeCanvas width={width} height={height} camera={{position: [0, 0, 5], fov: 50}}>
            <mesh position={[frame < 15 ? -1 : 1, 0, 0]}>
              <boxGeometry args={[1, 1, 1]} />
              <meshBasicMaterial color="#00ff00" toneMapped={false} />
            </mesh>
          </ThreeCanvas>;
        }
        """.write(to: root.appendingPathComponent("src/Composition.tsx"), atomically: true, encoding: .utf8)
        // fov 50 at distance 5 spans 4.66 units over 180 px: x = ±1 lands 39 px from centre.
        for (frame, x) in [(0, 121), (15, 199)] {
            let url = try await RemotionStillCapture.still(projectDir: root, frame: frame, width: 320, height: 180, runId: "three")
            let rep = try #require(NSImage(contentsOf: url)?.representations.first as? NSBitmapImageRep)
            let pixel = try #require(rep.colorAt(x: x, y: 90)?.usingColorSpace(.deviceRGB))
            #expect(pixel.greenComponent > 0.9 && pixel.redComponent < 0.1, "frame \(frame)")
        }
    }

    @Test("Bundled 3D libraries are advertised to in-app and MCP agents")
    func threeAuthoringInstructions() throws {
        let schema = Schema([AgentThread.self, AgentMessage.self])
        let container = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        for policy in AgentWritePolicy.allCases {
            let tools = AgentToolPolicy.descriptors(policy: policy)
            let write = try #require(tools.first { $0.name == "remotion_write_file" })
            for prefix in ["", "mcp__film_workflow__"] {
                // The prompt is an `AgentContext` now; `renderText()` is what the
                // SDK actually sends, so that is what the assertions read.
                let prompt = AgentPrompts.context(
                    target: AgentTarget.none, toolNames: tools.map(\.name),
                    policy: policy, context: container.mainContext, toolNamePrefix: prefix
                ).renderText()
                for name in ["three", "@react-three/fiber", "@remotion/three"] {
                    #expect(prompt.contains(name)); #expect(write.description.contains(name))
                }
                #expect(prompt.contains("ThreeCanvas")); #expect(prompt.contains("useCurrentFrame()"))
            }
        }
    }

    @Test("MCP preview, native live preview, screenshots, transparent renders, and document reopening")
    func completeWorkflow() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NativeRemotion-" + UUID().uuidString).appendingPathExtension("rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let result = try await MCPToolRegistry.invoke(name: "footage_create", arguments: ["kind":"remotion", "name":"Native Test"], container: document.container)
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let summary = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(summary["studio"] == nil)
        #expect((summary["preview"] as? [String: Any])?["status"] as? String == "ready")
        let context = document.container.mainContext
        let project = try #require(context.fetch(FetchDescriptor<RemotionProject>()).first)
        let source = """
        import React from 'react';import {AbsoluteFill,useCurrentFrame} from 'remotion';
        export const COMPOSITION_WIDTH=320,COMPOSITION_HEIGHT=180,COMPOSITION_FPS=30,COMPOSITION_DURATION_IN_FRAMES=3;
        export function MyComposition(){return <AbsoluteFill style={{color:'red',fontSize:60}}>Frame {useCurrentFrame()}</AbsoluteFill>}
        """
        try RemotionCodeBuilder.writeComposition(project: project, source: source)
        project.compositionSource = source
        try context.save()
        let descriptor = try RemotionLivePreview.descriptor(project: project, width: 320, height: 180)
        #expect(descriptor.url == project.projectDir.standardizedFileURL)
        _ = try await MotionSwiftEngine.prepare(projectDir: descriptor.url)
        let still = try await RemotionStillCapture.still(projectDir: project.projectDir, frame: 1, width: 320, height: 180, runId: "native-test")
        #expect(NSImage(contentsOf: still) != nil)
        let render = try await RemotionRenderService.ensureRender(project: project, width: 320, height: 180, fps: 30,
            context: context, preserveAlpha: true) { _ in }
        #expect(render.videoURL.pathExtension == "mov")
        #expect(RemotionRenderService.cachedRender(project: project, width: 320, height: 180, fps: 30, context: context, preserveAlpha: true)?.id == render.id)
        let renderID = render.id
        let sourceURL = project.projectDir.appendingPathComponent("src/Composition.tsx")
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == source)
        await document.close()
        let reopened = try ProjectDocument.open(url)
        #expect(try reopened.container.mainContext.fetch(FetchDescriptor<RemotionRender>()).contains { $0.id == renderID })
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == source)
        await reopened.close()
    }
}
