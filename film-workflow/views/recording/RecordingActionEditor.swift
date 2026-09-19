import AppKit
import SwiftUI
import SwiftData

struct RecordingActionEditor: View {
    @Bindable var project: ScreenRecordingProject
    let document: ProjectDocument
    @State private var selected: UUID?
    @State private var error: String?
    @Environment(\.undoManager) private var undoManager
    private var actions: [RecordingAction] { project.actions }
    private func edit(_ name: String = "Edit Recording Actions", _ transform: (inout [RecordingAction]) -> Void) {
        var next = actions; transform(&next)
        do { try RecordingActionDocumentService.replace(next, project: project, document: document, undoManager: undoManager, name: name) }
        catch { self.error = error.localizedDescription }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu("Add Action", systemImage: "plus") { ForEach(RecordingAction.Kind.allCases, id: \.self) { kind in Button(kind.rawValue) { edit { list in let action = RecordingAction(kind: kind, time: (list.last?.time ?? 0) + 1); list.append(action); selected = action.id } } } }
                Button("Duplicate", systemImage: "plus.square.on.square") { edit { list in if let index = list.firstIndex(where: { $0.id == selected }) { var value = list[index]; value.id = UUID(); value.time += 0.5; list.insert(value, at: index + 1); selected = value.id } } }.disabled(selected == nil)
                Button("Delete", systemImage: "trash") { edit { $0.removeAll { $0.id == selected } }; selected = nil }.disabled(selected == nil)
                Spacer()
                Button("Replay and Record", systemImage: "play.fill") { RecordingSetup.shared.open(project: project, document: document, replay: true) }.disabled(RecordingSession.shared.isActive || actions.isEmpty)
            }.padding()
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: max(700, ((actions.map { $0.time + $0.duration }.max() ?? 10) + 1) * 60), height: 70)
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        RoundedRectangle(cornerRadius: 4).fill(action.id == selected ? .blue : .gray.opacity(0.4))
                            .frame(width: max(8, action.duration * 60), height: 16).offset(x: action.time * 60, y: CGFloat(index % 3) * 21)
                            .onTapGesture { selected = action.id }.help("\(action.kind.rawValue) at \(action.time)s")
                    }
                }.padding(10)
            }.background(.quaternary)
            HSplitView {
                List(selection: $selected) {
                    ForEach(actions) { action in
                        HStack { Image(systemName: action.enabled ? "checkmark.circle" : "circle"); Text(action.kind.rawValue); Spacer(); Text(action.windowTitle.isEmpty ? action.bundleID : action.windowTitle).foregroundStyle(.secondary); Text(action.time, format: .number.precision(.fractionLength(2))).monospacedDigit() }.tag(action.id)
                    }.onMove { indices, destination in edit("Reorder Recording Actions") { list in
                        list.move(fromOffsets: indices, toOffset: destination)
                        var time = 0.0; for i in list.indices { list[i].time = time; time += max(0.05, list[i].duration) }
                    } }
                }.frame(minWidth: 400)
                if let id = selected, let action = actions.first(where: { $0.id == id }) {
                    RecordingSelectedAction(value: Binding(get: { project.actions.first { $0.id == id } ?? action }, set: { replacement in edit { list in if let index = list.firstIndex(where: { $0.id == id }) { list[index] = replacement } } }), document: document).frame(minWidth: 300, idealWidth: 360)
                } else { ContentUnavailableView("Select an Action", systemImage: "cursorarrow.motionlines", description: Text("Edit timing and targets, then replay to see the result.")) }
            }
            if let error { Text(error).foregroundStyle(.red).padding() }
        }.disabled(!RecordingSession.shared.canEditActions)
    }
}

private struct RecordingSelectedAction: View {
    @Binding var value: RecordingAction
    let document: ProjectDocument
    var body: some View {
        Form {
            Toggle("Enabled", isOn: $value.enabled)
            Picker("Action", selection: $value.kind) { ForEach(RecordingAction.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            TextField("Start (seconds)", value: $value.time, format: .number)
            TextField("Duration / timeout", value: $value.duration, format: .number)
            Picker("Motion", selection: Binding(get: { value.easing ?? .easeInOut }, set: { value.easing = $0 })) { ForEach(RecordingEasing.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            TextField("App bundle ID", text: $value.bundleID)
            TextField("Window title", text: $value.windowTitle)
            TextField("Window ID", text: Binding(get: { value.windowID.map(String.init) ?? "" }, set: { value.windowID = UInt32($0) }))
            TextField("Accessible target", text: Binding(get: { value.accessibilityIdentifier ?? "" }, set: { value.accessibilityIdentifier = $0.isEmpty ? nil : $0 }))
            HStack { TextField("X", value: $value.x, format: .number); TextField("Y", value: $value.y, format: .number) }
            HStack { TextField("End X", value: $value.endX, format: .number); TextField("End Y", value: $value.endY, format: .number) }
            if value.kind == .scroll { HStack { TextField("Horizontal", value: $value.deltaX, format: .number); TextField("Vertical", value: $value.deltaY, format: .number) } }
            if value.kind == .key { TextField("Key code", value: $value.keyCode, format: .number); TextField("Modifier flags", value: $value.modifiers, format: .number) }
            if [.text, .deviceText].contains(value.kind) { TextField("Text", text: $value.text, axis: .vertical) }
            if value.kind == .secureInput { Text("Secure input was omitted. Enter it manually during replay, then disable this step to continue.").foregroundStyle(.secondary) }
            if [.changeSource, .changeInputs].contains(value.kind) {
                let settings = Binding(get: { value.settings ?? RecordingSettings() }, set: { value.settings = $0 })
                RecordingSourcePicker(settings: settings)
                ForEach(RecordingSources.shared.cameras) { source in Toggle(source.name, isOn: input(source.id, keyPath: \.cameraIDs)) }
                ForEach(RecordingSources.shared.microphones) { source in Toggle(source.name, isOn: input(source.id, keyPath: \.microphoneIDs)) }
                Picker("App Sound", selection: settings.audioMode) { Text("Off").tag(RecordingAudioMode.off); Text("Selected Apps").tag(RecordingAudioMode.selectedApps); Text("All Apps").tag(RecordingAudioMode.allApps) }
                if settings.wrappedValue.audioMode == .selectedApps { ForEach(RecordingSources.shared.applications) { source in Toggle(source.name, isOn: input(source.id, keyPath: \.applicationBundleIDs)) } }
            }
            if let path = value.referenceImagePath, let image = NSImage(contentsOf: document.packageURL.appendingPathComponent(path)) { Image(nsImage: image).resizable().scaledToFit() }
            Text("Pointer coordinates are relative to the target window (0–1). Window positioning uses screen points. Changes take effect on the next replay.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
    private func input(_ id: String, keyPath: WritableKeyPath<RecordingSettings, [String]>) -> Binding<Bool> {
        Binding(get: { (value.settings ?? RecordingSettings())[keyPath: keyPath].contains(id) }, set: { enabled in
            var settings = value.settings ?? RecordingSettings(); settings[keyPath: keyPath].removeAll { $0 == id }
            if enabled { settings[keyPath: keyPath].append(id) }; value.settings = settings
        })
    }
}

struct RecordingDevicePreview: View {
    @Bindable var project: ScreenRecordingProject
    @State private var image: NSImage?
    @State private var error: String?
    @State private var text = ""
    @State private var busy = false
    var body: some View {
        VStack {
            if let image {
                GeometryReader { proxy in
                    Image(nsImage: image).resizable().scaledToFit().frame(width: proxy.size.width, height: proxy.size.height)
                        .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                            let scale = min(proxy.size.width / image.size.width, proxy.size.height / image.size.height)
                            let width = image.size.width * scale, height = image.size.height * scale
                            let ox = (proxy.size.width - width) / 2, oy = (proxy.size.height - height) / 2
                            var action = RecordingAction(kind: hypot(value.translation.width, value.translation.height) > 4 ? .deviceSwipe : .deviceTap)
                            action.x = (value.startLocation.x - ox) / width; action.y = (value.startLocation.y - oy) / height
                            action.endX = (value.location.x - ox) / width; action.endY = (value.location.y - oy) / height
                            if (0...1).contains(action.x), (0...1).contains(action.y) { perform(action) }
                        })
                }
            } else { ContentUnavailableView("Device Preview", systemImage: "iphone", description: Text("Connect a configured Appium device to control and record its actions.")) }
            HStack { TextField("Send text", text: $text); Button("Send") { var action = RecordingAction(kind: .deviceText); action.text = text; perform(action); text = "" } }.disabled(busy)
            Button("Refresh Device") { Task { await refresh() } }.disabled(busy)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding().task { await refresh() }
    }
    private func refresh() async { do { image = NSImage(data: try await RecordingDeviceAutomation.shared.screenshot(settings: project.settings)); error = nil } catch { self.error = error.localizedDescription } }
    private func perform(_ action: RecordingAction) { guard !busy else { return }; busy = true; Task { defer { busy = false }; do { try await RecordingDeviceAutomation.shared.perform(action, settings: project.settings); RecordingSession.shared.appendDeviceAction(action); await refresh() } catch { self.error = error.localizedDescription } } }
}

@MainActor enum RecordingActionDocumentService {
    static func replace(_ actions: [RecordingAction], project: ScreenRecordingProject, document: ProjectDocument, undoManager: UndoManager?, name: String = "Edit Recording Actions") throws {
        guard Set(actions.map(\.id)).count == actions.count else { throw RecordingError.message("Action IDs must be unique.") }
        for action in actions {
            guard action.time.isFinite, action.time >= 0, action.duration.isFinite, (0...3600).contains(action.duration), [action.x, action.y, action.endX, action.endY, action.deltaX, action.deltaY].allSatisfy(\.isFinite) else { throw RecordingError.message("Action timing and coordinates must be finite; duration must be between 0 and 3600 seconds.") }
            guard action.kind != .secureInput || action.text.isEmpty else { throw RecordingError.message("Secure input steps cannot store text.") }
        }
        let old = project.actions
        let revisions = document.packageURL.appendingPathComponent("Media/ScreenRecordings/\(project.id)/Actions", isDirectory: true)
        try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: true)
        try JSONEncoder().encode(actions).write(to: revisions.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        project.actions = actions; try document.container.mainContext.save()
        undoManager?.registerUndo(withTarget: project) { target in MainActor.assumeIsolated { try? replace(old, project: target, document: document, undoManager: undoManager, name: name) } }; undoManager?.setActionName(name)
    }
}
