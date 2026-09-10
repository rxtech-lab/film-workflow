import AppKit
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
    @State private var renders: [RemotionRender] = []
    @State private var showAllRenders = false
    @State private var refreshToken = 0
    @State private var pendingDeletion: RemotionRender?

    var body: some View {
        InspectorLayout(versionsTitle: "Renders", versionCount: renders.count) {
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
        } versions: {
            rendersList
        }
        .task(id: refreshToken) { renders = RemotionRenderService.renders(for: project, context: modelContext) }
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
        .sheet(isPresented: $showAllRenders) {
            NavigationStack {
                RemotionRenderListView(project: project, refreshToken: refreshToken)
                    .navigationTitle("Renders")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAllRenders = false; refreshToken += 1 } } }
            }
            .frame(minWidth: 760, minHeight: 460)
        }
        .alert("Render failed", isPresented: $showRenderError) { Button("OK") {} } message: { Text(renderError ?? "An unknown error occurred.") }
        .confirmationDialog("Delete this render?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible, presenting: pendingDeletion) { render in
            Button("Delete \(render.versionLabel)", role: .destructive) {
                RemotionRenderService.delete(render, context: modelContext)
                pendingDeletion = nil
                refreshToken += 1
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in Text("The rendered video file will be permanently deleted.") }
    }

    @ViewBuilder
    private var rendersList: some View {
        if renders.isEmpty {
            ContentUnavailableView {
                Label("No Renders", systemImage: "film")
            } description: {
                Text("Render to create the first version. Timeline renders also land here.")
            }
        } else {
            List(renders) { render in
                HStack(spacing: 10) {
                    if let url = render.thumbnailURL, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 56, height: 32)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(render.versionLabel).font(.callout.weight(.semibold))
                        Text(render.dimensionsLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(render.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.tertiary)
                }
                .contextMenu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([render.videoURL]) }
                    Button("Delete…", role: .destructive) { pendingDeletion = render }
                }
                .onTapGesture(count: 2) { showAllRenders = true }
            }
            .listStyle(.inset)
            .overlay(alignment: .bottomTrailing) {
                Button("Show All…") { showAllRenders = true }.controlSize(.small).padding(6)
            }
        }
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
