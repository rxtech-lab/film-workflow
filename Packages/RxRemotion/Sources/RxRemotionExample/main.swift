import AppKit
import RxRemotion
import RxRemotionUI
import SwiftUI

@main
struct Example: App {
    @State private var session: RemotionPreviewSession?
    @State private var error: String?
    @State private var exporting = false
    @State private var exportProgress = 0.0
    private let engine = RemotionEngine()
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--check") {
            let engine = engine
            Task { @MainActor in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RxRemotionExample-check-" + UUID().uuidString)
                do {
                    try RemotionEngine.scaffold(at: directory)
                    try "import {AbsoluteFill} from 'remotion';export const COMPOSITION_WIDTH=320,COMPOSITION_HEIGHT=180,COMPOSITION_FPS=30,COMPOSITION_DURATION_IN_FRAMES=3;export function MyComposition(){return <AbsoluteFill style={{background:'red'}}/>}".write(to: directory.appendingPathComponent("src/Composition.tsx"), atomically: true, encoding: .utf8)
                    let project = try await engine.prepare(projectURL: directory)
                    let preview = try await engine.makePreviewSession(project: project)
                    try await preview.seek(to: 1); preview.dispose()
                    try await engine.renderStill(project: project, frame: 1, to: directory.appendingPathComponent("frame.png"))
                    try await engine.renderMovie(project: project, to: directory.appendingPathComponent("movie.mp4"))
                    engine.closeAll(); try FileManager.default.removeItem(at: directory)
                    print("RxRemotion standalone check passed: compile, preview, PNG, and movie export")
                    exit(EXIT_SUCCESS)
                } catch {
                    engine.closeAll(); try? FileManager.default.removeItem(at: directory)
                    FileHandle.standardError.write(Data("Standalone check failed: \(error.localizedDescription)\n".utf8))
                    exit(EXIT_FAILURE)
                }
            }
        }
    }
    var body: some Scene {
        Window("RxRemotion", id: "preview") {
            VStack {
                if let session {
                    RemotionPreview(session: session)
                    HStack {
                        Button("Play") { Task { try? await session.play() } }
                        Button("Pause") { Task { try? await session.pause() } }
                        Button("First Frame") { Task { try? await session.seek(to: 0) } }
                        Text("Frame \(session.frame)").monospacedDigit()
                        Button("Export Movie…") { exportMovie() }.disabled(exporting)

                    }
                } else if let error { Text(error).textSelection(.enabled) }
                else { ProgressView("Preparing composition…") }
                if exporting { ProgressView(value: exportProgress).padding() }
                if session != nil, let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.frame(minWidth: 800, minHeight: 500).task {
                guard !CommandLine.arguments.contains("--check") else { return }
                do {
                    let path = CommandLine.arguments.dropFirst().first
                    let directory = path.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("RxRemotionExample")
                    try RemotionEngine.scaffold(at: directory)
                    let project = try await engine.prepare(projectURL: directory)
                    session = try await engine.makePreviewSession(project: project)
                    print("RxRemotion standalone preview ready")
                } catch { self.error = error.localizedDescription }
            }.onDisappear { session?.dispose(); engine.closeAll() }
        }
    }
    private func exportMovie() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "remotion.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true; exportProgress = 0
        Task { @MainActor in
            defer { exporting = false }
            do {
                let directory = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("RxRemotionExample")
                let project = try await engine.prepare(projectURL: directory)
                try await engine.renderMovie(project: project, to: url) { update in exportProgress = update.fraction ?? 0 }
            } catch { self.error = error.localizedDescription }
        }
    }
}
