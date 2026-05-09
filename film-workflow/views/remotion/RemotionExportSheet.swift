#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ExportResolution: String, CaseIterable, Identifiable {
    case p480, p720, p1080, p1440, p2160

    var id: String { rawValue }

    var label: String {
        switch self {
        case .p480: return "480p (854 × 480)"
        case .p720: return "720p (1280 × 720)"
        case .p1080: return "1080p (1920 × 1080)"
        case .p1440: return "1440p (2560 × 1440)"
        case .p2160: return "4K (3840 × 2160)"
        }
    }

    var shortLabel: String {
        switch self {
        case .p480: return "480p"
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }

    var size: (width: Int, height: Int) {
        switch self {
        case .p480: return (854, 480)
        case .p720: return (1280, 720)
        case .p1080: return (1920, 1080)
        case .p1440: return (2560, 1440)
        case .p2160: return (3840, 2160)
        }
    }
}

enum ExportFrameRate: Int, CaseIterable, Identifiable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }
}

struct RemotionExportOptions: Equatable {
    var resolution: ExportResolution = .p1080
    var frameRate: ExportFrameRate = .fps30
    var destination: URL
}

struct RemotionExportSheet: View {
    let projectName: String
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceFps: Int
    @Binding var options: RemotionExportOptions
    var onCancel: () -> Void
    var onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                resolutionRow
                frameRateRow
                destinationRow
                summary
            }
            .padding(20)

            Divider()

            footer
        }
        .frame(width: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export Video")
                    .font(.headline)
                Text(projectName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(20)
    }

    private var resolutionRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Resolution")
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            Picker("", selection: $options.resolution) {
                ForEach(ExportResolution.allCases) { res in
                    Text(res.label).tag(res)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var frameRateRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Frame Rate")
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            Picker("", selection: $options.frameRate) {
                ForEach(ExportFrameRate.allCases) { fps in
                    Text(fps.label).tag(fps)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var destinationRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Save To")
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(options.destination.path)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…") { chooseDestination() }
                    .controlSize(.small)
            }
        }
    }

    private var summary: some View {
        let (w, h) = options.resolution.size
        return Text("Composition is \(sourceWidth) × \(sourceHeight) @ \(sourceFps)fps. Output will be \(w) × \(h) @ \(options.frameRate.rawValue)fps.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Export…") { onExport() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = options.destination.lastPathComponent
        panel.directoryURL = options.destination.deletingLastPathComponent()
        panel.title = "Choose Export Location"

        if panel.runModal() == .OK, let url = panel.url {
            options.destination = url
        }
    }
}
#endif
