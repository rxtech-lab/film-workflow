import AppKit
import FilmTemplateKit
import JSONSchemaForm
import SwiftUI
import UniformTypeIdentifiers

/// The file field JSONSchemaForm does not ship.
///
/// Registered under `ui:widget: "file-picker"`. The value is an array of file
/// paths, which is what the wizard needs to import them and what a plain JSON
/// schema can describe.
public enum FilePickerWidget {
    public static let name = IntakeFormDefinition.filePickerWidget

    public static let widget: JSONSchemaFormWidget = { context in
        AnyView(FilePickerField(
            paths: Binding(
                get: { context.formData.wrappedValue.array?.compactMap(\.string) ?? [] },
                set: { context.formData.wrappedValue = .array(items: $0.map { .string($0) }) }
            ),
            contentTypes: contentTypes(from: context.uiSchema)
        ))
    }

    /// `ui:options.accept` names broad media families rather than UTIs, so a
    /// template author does not have to know about `public.movie`.
    static func contentTypes(from uiSchema: [String: Any]?) -> [UTType] {
        let options = uiSchema?["ui:options"] as? [String: Any]
        let accept = (options?["accept"] as? [Any])?.compactMap { $0 as? String }
        guard let accept, !accept.isEmpty else { return [.movie, .image, .audio] }
        return accept.flatMap { family -> [UTType] in
            switch family.lowercased() {
            case "video", "movie": [.movie, .video]
            case "image": [.image]
            case "audio", "music": [.audio]
            default: []
            }
        }
    }
}

struct FilePickerField: View {
    @Binding var paths: [String]
    let contentTypes: [UTType]

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if paths.isEmpty {
                emptyState
            } else {
                VStack(spacing: 6) {
                    ForEach(paths, id: \.self) { path in
                        FilePickerRow(path: path) { remove(path) }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    FilmTemplateTip.uploads.didPerform()
                    chooseFiles()
                } label: {
                    Label("Add Files…", systemImage: "plus")
                }
                .accessibilityIdentifier("intake.uploads.add")
                .templateTip(.uploads, when: paths.isEmpty)

                if !paths.isEmpty {
                    Button("Remove All", role: .destructive) { paths = [] }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
                Spacer(minLength: 0)
                if !paths.isEmpty {
                    Text(String(localized: "\(paths.count) file\(paths.count == 1 ? "" : "s")"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(
            Color.primary.opacity(isTargeted ? 0.08 : 0.03),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.primary.opacity(0.07),
                    style: StrokeStyle(lineWidth: 1, dash: paths.isEmpty ? [4, 3] : [])
                )
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            load(providers)
            return true
        }
        .accessibilityIdentifier("intake.uploads")
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop files here, or add them below.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = contentTypes
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose footage, images or music for this film.")
        guard panel.runModal() == .OK else { return }
        append(panel.urls)
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in append([url]) }
            }
        }
    }

    private func append(_ urls: [URL]) {
        // Same file twice is always a mistake here, and a duplicate would be
        // imported twice into the film.
        let existing = Set(paths)
        let added = urls.map(\.path).filter { !existing.contains($0) }
        guard !added.isEmpty else { return }
        paths.append(contentsOf: added)
    }

    private func remove(_ path: String) {
        paths.removeAll { $0 == path }
    }
}

struct FilePickerRow: View {
    let path: String
    let onRemove: () -> Void

    private var url: URL { URL(fileURLWithPath: path) }

    private var size: String? {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size {
                    Text(size).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove \(url.lastPathComponent)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    }
}
