#if DEBUG
import Foundation
import SwiftData

/// Builds actual movies in a disposable film for the UI test process. No mock
/// player or alternate library view: tests exercise the normal editor window.
@MainActor
enum RemotionFootageUITestFixture {
    static func openIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-uiTesting"),
              let path = ProcessInfo.processInfo.environment["RXFILM_REMOTION_UI_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let controller = ProjectDocumentController.shared
            let document = try controller.createDocument(at: root.appendingPathComponent("Remotion UI Test.rxfilmstudio"))
            let context = document.container.mainContext
            let project = RemotionProject(name: "Remotion Versions")
            project.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            project.durationSeconds = 4
            project.compositionWidth = 320; project.compositionHeight = 180; project.compositionFps = 10
            context.insert(project)
            for (offset, colors) in [("red", "blue"), ("lime", "yellow"), ("magenta", "cyan")].enumerated() {
                let code = """
                import React from 'react'; import {AbsoluteFill,useCurrentFrame} from 'remotion';
                export const COMPOSITION_WIDTH=320,COMPOSITION_HEIGHT=180,COMPOSITION_FPS=10,COMPOSITION_DURATION_IN_FRAMES=40;
                export function MyComposition(){return <AbsoluteFill style={{backgroundColor:useCurrentFrame()<20?'\(colors.0)':'\(colors.1)'}}/>}
                """
                project.compositionSource = code
                try RemotionCodeBuilder.writeComposition(project: project, source: code)
                let render = try await RemotionRenderService.ensureRender(project: project, width: 320, height: 180, fps: 10,
                    context: context, preserveAlpha: offset == 1) { _ in }
                render.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", offset + 11))!
                if offset == 0 {
                    let video = ImportedAsset(name: "Reference Video", kind: .video, originalPath: render.videoURL.path)
                    video.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
                    video.relativePath = render.filePath; video.thumbnailFilePath = render.thumbnailFilePath
                    video.durationSeconds = 4; video.width = 320; video.height = 180
                    context.insert(video)
                }
            }
            let live = RemotionProject(name: "Live Remotion")
            live.id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
            live.durationSeconds = 4; live.compositionWidth = 320; live.compositionHeight = 180; live.compositionFps = 10
            live.compositionSource = project.compositionSource
            context.insert(live)
            try RemotionCodeBuilder.writeComposition(project: live, source: live.compositionSource)
            try context.save()
            document.setFootageBrowserVisible(true)
            document.setPanelSizes([220, 380], for: .libraryRows)
            controller.requestOpen(document.packageURL)
        } catch {
            try? error.localizedDescription.write(to: root.appendingPathComponent("fixture-error.txt"), atomically: true, encoding: .utf8)
        }
    }
}
#endif
