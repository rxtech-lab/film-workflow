import SwiftData
import SwiftUI

struct RemotionInspector: View {
    let project: RemotionProject
    @Environment(\.modelContext) private var modelContext

    @State private var statusMessage: String?
    @State private var isSeeding = false
    @State private var showSourceSheet = false
    @State private var showExportSheet = false
    @State private var exportOptions = RemotionExportOptions()
    @State private var renderTask: Task<Void, Never>?
    @State private var renderProgress = RenderProgress(stage: .starting, fraction: nil, detail: nil)
    @State private var showProgressSheet = false
    @State private var renderError: String?
    @State private var showRenderError = false
    @State private var refreshToken = 0

    var body: some View {
        VStack(spacing: 0) {
            RemotionParametersView(project: project, statusMessage: $statusMessage, isSeeding: $isSeeding)
            Divider()
            HStack(spacing: 8) {
                Button { showSourceSheet = true } label: { Label("Source", systemImage: "doc.text") }
                    .disabled(project.compositionSource.isEmpty)
                GenerateButton(title: "Render", isBusy: showProgressSheet, isEnabled: !project.compositionSource.isEmpty) {
                    beginRender()
                }
            }
            .padding(10)
        }
        .sheet(isPresented: $showSourceSheet) {
            RemotionSourceSheetView(projectDir: project.projectDir, refreshToken: refreshToken) { showSourceSheet = false }
        }
        .sheet(isPresented: $showExportSheet) {
            RemotionExportSheet(projectName: project.name, sourceWidth: project.compositionWidth, sourceHeight: project.compositionHeight,
                                sourceFps: project.compositionFps, options: $exportOptions,
                                onCancel: { showExportSheet = false },
                                onExport: { showExportSheet = false; startRender() })
        }
        .sheet(isPresented: $showProgressSheet) {
            RemotionRenderProgressSheet(projectName: project.name, progress: $renderProgress) { renderTask?.cancel() }
        }
        .alert("Render failed", isPresented: $showRenderError) { Button("OK") {} } message: { Text(renderError ?? "An unknown error occurred.") }
    }

    private func beginRender() {
        guard !showProgressSheet else { return }
        let res = ExportResolution.allCases.first {
            $0.size.width == project.compositionWidth && $0.size.height == project.compositionHeight
        } ?? .p1080
        exportOptions = RemotionExportOptions(resolution: res, frameRate: ExportFrameRate(rawValue: project.compositionFps) ?? .fps30)
        showExportSheet = true
    }

    private func startRender() {
        renderError = nil
        renderProgress = RenderProgress(stage: .starting, fraction: nil, detail: nil)
        showProgressSheet = true
        let (w, h) = exportOptions.resolution.size
        let fps = exportOptions.frameRate.rawValue
        renderTask = Task { @MainActor in
            defer { showProgressSheet = false; renderTask = nil }
            do {
                _ = try await RemotionRenderService.ensureRender(project: project, width: w, height: h, fps: fps, context: modelContext, force: true) { p in
                    renderProgress = p
                }
                refreshToken += 1
                // The renderer stops Studio; bring the preview back.
                try? await RemotionRuntime.shared.start(projectId: project.id, projectDir: project.projectDir)
            } catch is CancellationError {
            } catch {
                renderError = error.localizedDescription
                showRenderError = true
            }
        }
    }
}
