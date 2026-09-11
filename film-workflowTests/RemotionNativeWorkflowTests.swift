import AppKit
import Foundation
import RxAgentSDK
import RxRemotion
import SwiftData
import Testing
import WebKit
@testable import film_workflow

@Suite("Native Remotion workflow", .serialized) @MainActor
struct RemotionNativeWorkflowTests {
    @Test("ThreeCanvas draws and seeks in the native preview")
    func threeScenePreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ThreePreview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try RemotionEngine.scaffold(at: root)
        try """
        import {Color, Mesh} from 'three';import {useThree} from '@react-three/fiber';
        import {Box} from '@react-three/drei';import {ThreeCanvas} from '@remotion/three';
        import {useCurrentFrame, useVideoConfig} from 'remotion';
        export const COMPOSITION_WIDTH=320,COMPOSITION_HEIGHT=180,COMPOSITION_FPS=30,COMPOSITION_DURATION_IN_FRAMES=30;
        function Scene(){const frame=useCurrentFrame();const {gl}=useThree();return <Box
          position={[frame<15?-1:1,0,0]} onAfterRender={function(){
            if(!(this instanceof Mesh))throw new Error('Three.js module identity mismatch');
            const context=gl.getContext(),pixel=new Uint8Array(4);
            context.readPixels(frame<15?100:220,90,1,1,context.RGBA,context.UNSIGNED_BYTE,pixel);
            gl.domElement.dataset.renderedFrame=String(frame);gl.domElement.dataset.green=String(pixel[1]);
          }}><meshBasicMaterial color={new Color('#00ff00')} toneMapped={false}/></Box>}
        export function MyComposition(){const {width,height}=useVideoConfig();return <ThreeCanvas
          width={width} height={height} dpr={1} orthographic camera={{position:[0,0,5],zoom:60}}
          gl={{alpha:true,antialias:false,preserveDrawingBuffer:true}}><Scene/></ThreeCanvas>}
        """.write(to: root.appendingPathComponent("src/Composition.tsx"), atomically: true, encoding: .utf8)
        let engine = RemotionEngine(); defer { engine.closeAll() }
        let project = try await engine.prepare(projectURL: root)
        let preview = try await engine.makePreviewSession(project: project, settings: .init(width: 320, height: 180))
        defer { preview.dispose() }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 180),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = preview.webView
        window.orderFrontRegardless(); defer { window.close() }
        for frame in [0, 15, 0] {
            try await preview.seek(to: frame)
            for _ in 0..<150 {
                if try await preview.webView.evaluateJavaScript("document.querySelector('canvas')?.dataset.renderedFrame") as? String == String(frame) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let renderedFrame = try await preview.webView.evaluateJavaScript("document.querySelector('canvas')?.dataset.renderedFrame") as? String
            let green = try await preview.webView.evaluateJavaScript("Number(document.querySelector('canvas')?.dataset.green)") as? Int
            #expect(preview.lastError == nil)
            #expect(renderedFrame == String(frame)); #expect(green == 255)
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
                for name in ["three", "@react-three/fiber", "@react-three/drei", "@remotion/three"] {
                    #expect(prompt.contains(name)); #expect(write.description.contains(name))
                }
                #expect(prompt.contains("ThreeCanvas")); #expect(prompt.contains("useCurrentFrame()"))
            }
        }
    }

    @Test("MCP preview, independent leases, screenshots, transparent renders, and document reopening")
    func completeWorkflow() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NativeRemotion-" + UUID().uuidString).appendingPathExtension("rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let result = try await MCPToolRegistry.invoke(name: "create_project", arguments: ["type":"remotion", "name":"Native Test"], container: document.container)
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let summary = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(summary["studio"] == nil)
        #expect((summary["preview"] as? [String: Any])?["status"] as? String == "running")
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
        let first = try await RemotionPreviewSessions.shared.acquire(project: project)
        let second = try await RemotionPreviewSessions.shared.acquire(project: project)
        #expect(first.url == second.url)
        first.release()
        let (_, response) = try await URLSession.shared.data(from: second.url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let still = try await RemotionStillCapture.still(projectDir: project.projectDir, frame: 1, width: 320, height: 180, runId: "native-test")
        #expect(NSImage(contentsOf: still) != nil)
        let render = try await RemotionRenderService.ensureRender(project: project, width: 320, height: 180, fps: 30,
            context: context, preserveAlpha: true) { _ in }
        #expect(render.videoURL.pathExtension == "mov")
        #expect(RemotionRenderService.cachedRender(project: project, width: 320, height: 180, fps: 30, context: context, preserveAlpha: true)?.id == render.id)
        let renderID = render.id
        let sourceURL = project.projectDir.appendingPathComponent("src/Composition.tsx")
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == source)
        second.release()
        await document.close()
        let reopened = try ProjectDocument.open(url)
        #expect(try reopened.container.mainContext.fetch(FetchDescriptor<RemotionRender>()).contains { $0.id == renderID })
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == source)
        await reopened.close()
    }
}
