import AppKit
import SwiftData
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// Output choices before a sequence render: video and audio codecs, size,
/// container and where the file goes. Menu pickers throughout; the last
/// choices are remembered across films.
struct SequenceRenderSheet: View {
    let sequence: SequenceProject
    let onRender: (TimelineExporter.Options, SequenceRenderDestination) -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var options = SequenceRenderDefaults.options
    @State private var destination: DestinationChoice = SequenceRenderDefaults.folder.map { .folder($0) } ?? .film

    /// Picker tags: the menu shows the film, the last folder, and "Other…".
    enum DestinationChoice: Hashable {
        case film
        case folder(URL)
        case choose
    }

    private var nextVersion: Int {
        (SequenceRenderService.renders(for: sequence, context: modelContext).map(\.versionNumber).max() ?? 0) + 1
    }

    private var canRender: Bool { options.video != nil || options.audio != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                row("Video") {
                    Picker("", selection: $options.video) {
                        ForEach(TimelineExporter.VideoCodec.allCases, id: \.self) { codec in
                            Text(codec.displayName).tag(Optional(codec))
                        }
                        Divider()
                        Text("None (Audio Only)").tag(Optional<TimelineExporter.VideoCodec>.none)
                    }
                }
                row("Audio") {
                    Picker("", selection: $options.audio) {
                        ForEach(TimelineExporter.AudioCodec.allCases, id: \.self) { codec in
                            Text(codec.displayName).tag(Optional(codec))
                        }
                        Divider()
                        Text("None (Silent)").tag(Optional<TimelineExporter.AudioCodec>.none)
                    }
                }
                row("Resolution") {
                    Picker("", selection: $options.resolution) {
                        ForEach(TimelineExporter.Resolution.allCases, id: \.self) { res in
                            Text(resolutionLabel(res)).tag(res)
                        }
                    }
                    .disabled(options.isAudioOnly)
                }
                row("Format") {
                    Picker("", selection: $options.container) {
                        ForEach(TimelineExporter.Container.choices(audioOnly: options.isAudioOnly), id: \.self) { container in
                            Text("\(container.displayName) (.\(container.fileExtension))").tag(container)
                        }
                    }
                }
                row("Save To") {
                    Picker("", selection: $destination) {
                        Label("This Film · Version \(nextVersion)", systemImage: "film.stack").tag(DestinationChoice.film)
                        if case .folder(let url) = destination {
                            Label(url.lastPathComponent, systemImage: "folder").tag(DestinationChoice.folder(url))
                        } else if let remembered = SequenceRenderDefaults.folder {
                            Label(remembered.lastPathComponent, systemImage: "folder").tag(DestinationChoice.folder(remembered))
                        }
                        Divider()
                        Text("Other Folder…").tag(DestinationChoice.choose)
                    }
                }
                summary
                let stale = SequenceRenderService.unrenderedRemotionProjects(in: sequence, context: modelContext)
                if !stale.isEmpty {
                    Label("\(stale.count) Remotion clip\(stale.count == 1 ? "" : "s") will be rendered first: \(stale.map(\.name).joined(separator: ", "))", systemImage: "atom")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 500)
        .onChange(of: options.video) { _, _ in options = options.normalized }
        .onChange(of: destination) { old, new in
            guard new == .choose else { return }
            if let url = chooseFolder() {
                SequenceRenderDefaults.folder = url
                destination = .folder(url)
            } else {
                destination = old
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "film.stack").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Render Sequence").font(.headline)
                Text(sequence.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(20)
    }

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resolutionLabel(_ res: TimelineExporter.Resolution) -> String {
        let size = res.size(for: sequence.timeline.size)
        return "\(res.displayName) (\(Int(size.width)) × \(Int(size.height)))"
    }

    private var summary: some View {
        var parts: [String] = []
        if let size = options.outputSize(for: sequence.timeline.size) {
            parts.append("\(Int(size.width)) × \(Int(size.height)) @ \(sequence.fps) fps")
        }
        parts.append(Timecode.string(seconds: sequence.timeline.duration, fps: sequence.fps))
        parts.append(options.summary)
        let location: String
        switch destination {
        case .folder(let url):
            let file = SequenceRenderService.unusedFileURL(in: url, name: sequence.name, ext: options.fileExtension)
            location = "Saved as \((file.path as NSString).abbreviatingWithTildeInPath), not kept as a film version."
        case .film, .choose:
            location = "Saved into the film as version \(nextVersion)."
        }
        return Text(parts.joined(separator: " · ") + ". " + location)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button("Render") {
                SequenceRenderDefaults.options = options
                let target: SequenceRenderDestination
                if case .folder(let url) = destination { target = .folder(url) } else { target = .film }
                onRender(options.normalized, target)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canRender)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for the rendered file."
        panel.directoryURL = SequenceRenderDefaults.folder
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// The last render choices, shared by every film.
enum SequenceRenderDefaults {
    private static let optionsKey = "sequenceRender.options"
    private static let folderKey = "sequenceRender.folder"

    static var options: TimelineExporter.Options {
        get {
            guard let data = UserDefaults.standard.data(forKey: optionsKey),
                  let decoded = try? JSONDecoder().decode(TimelineExporter.Options.self, from: data) else {
                return TimelineExporter.Options()
            }
            return decoded.normalized
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: optionsKey)
        }
    }

    /// The last folder picked, if it still exists.
    static var folder: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: folderKey) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: folderKey)
        }
    }
}

struct SequenceRenderProgressSheet: View {
    let sequenceName: String
    let progress: SequenceRenderProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "film.stack").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rendering Sequence").font(.headline)
                    Text(sequenceName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(progress.label).font(.subheadline.weight(.medium))
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
