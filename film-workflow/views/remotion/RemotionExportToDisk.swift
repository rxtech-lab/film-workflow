#if os(macOS)
import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Exports a Remotion project to a file the user picks: output options, a
/// save panel, then a render (or a matching cached one) copied into place.
/// Set `project` to start; it is cleared when the options sheet closes.
struct RemotionExportToDiskModifier: ViewModifier {
    @Binding var project: RemotionProject?

    @Environment(\.modelContext) private var modelContext
    @State private var options = RemotionExportOptions()
    @State private var renderTask: Task<Void, Never>?
    @State private var progress = RenderProgress(stage: .starting, fraction: nil, detail: nil)
    @State private var renderingName = ""
    @State private var showProgress = false
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { project != nil }, set: { if !$0 { project = nil } })) {
                if let project {
                    RemotionExportSheet(
                        projectName: project.name,
                        sourceWidth: project.compositionWidth,
                        sourceHeight: project.compositionHeight,
                        sourceFps: project.compositionFps,
                        options: $options,
                        savesToDisk: true,
                        onCancel: { self.project = nil },
                        onExport: {
                            guard let destination = chooseDestination(for: project) else { return }
                            self.project = nil
                            start(project, to: destination)
                        }
                    )
                    .onAppear { options = Self.defaultOptions(for: project) }
                }
            }
            .sheet(isPresented: $showProgress) {
                RemotionRenderProgressSheet(projectName: renderingName, progress: $progress) { renderTask?.cancel() }
            }
            .alert("Export failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "An unknown error occurred.")
            }
    }

    /// The composition's own size and rate, falling back to 1080p30.
    private static func defaultOptions(for project: RemotionProject) -> RemotionExportOptions {
        let resolution = ExportResolution.allCases.first {
            $0.size.width == project.compositionWidth && $0.size.height == project.compositionHeight
        } ?? .p1080
        return RemotionExportOptions(resolution: resolution, frameRate: ExportFrameRate(rawValue: project.compositionFps) ?? .fps30)
    }

    private func chooseDestination(for project: RemotionProject) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.title = "Export Remotion Footage"
        panel.nameFieldStringValue = "\(project.name)-\(options.resolution.shortLabel).mp4"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func start(_ project: RemotionProject, to destination: URL) {
        guard !project.compositionSource.isEmpty else {
            errorMessage = "\(project.name) has no composition to export yet."
            return
        }
        let (width, height) = options.resolution.size
        let fps = options.frameRate.rawValue
        renderingName = project.name
        progress = RenderProgress(stage: .starting, fraction: nil, detail: nil)
        showProgress = true
        renderTask = Task { @MainActor in
            defer { showProgress = false; renderTask = nil }
            do {
                let render = try await RemotionRenderService.ensureRender(project: project, width: width, height: height, fps: fps, context: modelContext) { p in
                    progress = p
                }
                try RemotionRenderService.export(render, to: destination)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension View {
    /// Presents the export-to-disk flow for `project` whenever it is non-nil.
    func remotionExportToDisk(project: Binding<RemotionProject?>) -> some View {
        modifier(RemotionExportToDiskModifier(project: project))
    }
}
#endif
