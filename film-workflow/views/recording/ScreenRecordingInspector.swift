import AppKit
import SwiftData
import SwiftUI
import VideoEditorCore
import VideoEditorUI

struct ScreenRecordingInspector: View {
    @Bindable var project: ScreenRecordingProject
    let context: InspectorContext
    @State private var sources = RecordingSources.shared
    @State private var session = RecordingSession.shared
    @State private var permissions = RecordingPermissions.shared
    @State private var showingPermissions = !RecordingPermissions.shared.granted.isSuperset(of: RecordingPermission.allCases)
    @State private var error: String?
    @State private var pendingTakeRemoval: RecordingTake?
    @State private var screenshotApp = false
    @State private var screenshotBundle = ""
    @State private var screenshotCursor = false
    @Environment(\.undoManager) private var undoManager
    private var settings: Binding<RecordingSettings> { Binding(get: { project.settings }, set: { project.settings = $0 }) }
    var body: some View {
        Group {
            if !permissions.baseGranted || showingPermissions {
                ScrollView {
                    RecordingPermissionGuide(showsAllPermissions: true)
                    if permissions.baseGranted {
                        Button("Back to Recording", systemImage: "arrow.left") { showingPermissions = false }
                            .accessibilityIdentifier("recording.permissions.done")
                            .padding(.bottom, 20)
                    }
                }
            } else {
                Form {
                    Section("Permissions") {
                        LabeledContent("Access granted", value: "\(permissions.granted.count) of \(RecordingPermission.allCases.count)")
                        Button("Manage Recording Permissions", systemImage: "lock.shield") { showingPermissions = true }
                            .accessibilityIdentifier("recording.permissions.manage")
                    }
                    Section("Takes") {
                        if project.visibleTakes.isEmpty {
                            Text("Click Record below to choose what to capture. Your takes will appear here.").foregroundStyle(.secondary)
                        }
                        ForEach(project.visibleTakes.sorted { $0.createdAt > $1.createdAt }) { take in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top) {
                                    Text(take.name).font(.headline)
                                    Spacer(minLength: 8)
                                    RecordingTakeRemoveButton(take: take, selection: $pendingTakeRemoval).labelStyle(.iconOnly).buttonStyle(.borderless)
                                }
                                Text("\(take.duration, specifier: "%.1f")s · \(take.components.count) tracks\(take.isInterrupted ? " · Interrupted" : "")").font(.caption)
                                Button("Add to Timeline", systemImage: "plus.rectangle.on.rectangle") {
                                    do {
                                        guard let sequence = context.sequence else { throw RecordingError.message("Create or select a sequence first.") }
                                        let ids = try RecordingTimelineService.insert(take: take, into: sequence, at: context.state.playhead, undoManager: undoManager)
                                        context.state.selectedClipID = ids.first
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                    DisclosureGroup("Presentation Defaults") { RecordingPresentationEditor(value: Binding(get: { project.presentation }, set: { project.presentation = $0 })) }
                    DisclosureGroup("Shortcut Subtitle Style") { TextStyleEditor(style: Binding(get: { project.shortcutStyle }, set: { project.shortcutStyle = $0 })) }
                    DisclosureGroup("Screenshots") {
                        Toggle("Capture Every Window of an App", isOn: $screenshotApp)
                        Toggle("Include Cursor", isOn: $screenshotCursor)
                        if screenshotApp { Picker("App", selection: $screenshotBundle) { Text("Choose an app").tag(""); ForEach(sources.applications) { Text($0.name).tag($0.id) } } }
                        Button("Take Screenshot", systemImage: "camera") {
                            Task {
                                do {
                                    let window = project.settings.sourceKind == .window ? project.settings.selectedWindowIDs.first.flatMap(UInt32.init) : RecordingFocusContext.lastExternalWindow?.windowID
                                    let results = try await RecordingScreenshotService.capture(windowID: screenshotApp ? nil : window, bundleID: screenshotApp ? screenshotBundle : nil, includeCursor: screenshotCursor, saveTo: context.document)
                                    error = results.compactMap(\.error).joined(separator: "\n").nilIfEmpty
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                    DisclosureGroup("Recording Actions") {
                        Button("Edit Recording Movement", systemImage: "cursorarrow.motionlines") { RecordingWindows.shared.showEditor(project: project, document: context.document) }
                        Text("Record actions from the Record menu, then edit and replay them.").font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Device Automation") {
                        Text(RecordingDeviceAutomation.shared.setupInstructions).font(.caption).foregroundStyle(.secondary)
                        TextField("Appium URL", text: settings.deviceAutomationURL)
                        TextField("Device UDID", text: settings.deviceUDID)
                        TextField("App bundle ID", text: settings.deviceAppBundleID)
                        Button("Open Device Control", systemImage: "iphone") { RecordingWindows.shared.showDevice(project: project) }
                    }.disabled(session.isActive)
                    if let message = error ?? session.error ?? sources.error { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                }.formStyle(.grouped)
            }
        }
        .modifier(RecordingTakeRemovalConfirmation(take: $pendingTakeRemoval))
        .task(id: permissions.baseGranted) {
            permissions.refresh()
            if permissions.baseGranted { do { try await sources.refresh() } catch { sources.error = error.localizedDescription } }
        }
    }
}

struct RecordingInspectorFooter: View {
    let project: ScreenRecordingProject
    let context: InspectorContext
    @State private var session = RecordingSession.shared
    @State private var permissions = RecordingPermissions.shared
    var body: some View {
        VStack(spacing: 8) {
            if session.isActive, session.project?.id == project.id {
                Text("\(session.phase.rawValue) · \(session.elapsed, specifier: "%.1f")s").font(.caption).monospacedDigit()
                HStack {
                    if session.phase == .paused { Button("Resume", systemImage: "play.fill") { session.resume() } }
                    else { Button("Pause", systemImage: "pause.fill") { session.pause() }.disabled(!session.canPause) }
                    Button("Stop Recording", systemImage: "stop.fill") { Task { await session.stop() } }.buttonStyle(.borderedProminent).tint(.red)
                }.disabled(session.phase == .finalizing)
            } else {
                HStack(spacing: 6) {
                    Button {
                        RecordingSetup.shared.open(project: project, document: context.document)
                    } label: {
                        Label(permissions.baseGranted ? "Record" : "Set Up Recording", systemImage: "record.circle").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("recording.setup")
                    Menu {
                        Button("Record Content") { open(mode: .content) }
                        Button("Record Actions") { open(mode: .actions) }
                        Button("Replay and Record") { RecordingSetup.shared.open(project: project, document: context.document, replay: true) }.disabled(project.actions.isEmpty)
                    } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize()
                }.disabled(session.isActive)
            }
        }.padding(10)
    }
    private func open(mode: ScreenRecordingMode) {
        RecordingSetup.shared.open(project: project, document: context.document)
        if RecordingSetup.shared.project?.id == project.id { RecordingSetup.shared.pending.mode = mode }
    }
}

struct RecordingSourcePicker: View {
    @Binding var settings: RecordingSettings
    @State private var sources = RecordingSources.shared
    var body: some View {
        Picker("Source", selection: $settings.sourceKind) { ForEach(RecordingSourceKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
        Picker(settings.sourceKind == .device ? "Device screen" : "Target", selection: Binding(get: { settings.sourceID }, set: { settings.sourceID = $0; if settings.sourceKind == .window { settings.selectedWindowIDs = $0.isEmpty ? [] : [$0] } })) {
            Text("Choose a source").tag("")
            ForEach(settings.sourceKind == .window ? sources.windows : settings.sourceKind == .device ? sources.deviceScreens : sources.displays) { Text($0.name).tag($0.id) }
        }
        if settings.sourceKind == .window {
            ForEach(sources.windows) { source in
                Toggle(source.name, isOn: Binding(get: { settings.selectedWindowIDs.contains(source.id) }, set: { enabled in
                    var ids = settings.selectedWindowIDs; ids.removeAll { $0 == source.id }; if enabled { ids.append(source.id) }; settings.selectedWindowIDs = ids
                }))
            }
        }
        if settings.sourceKind == .area {
            HStack { TextField("X", value: Binding(get: { Double(settings.area.origin.x) }, set: { settings.area.origin.x = CGFloat($0) }), format: .number); TextField("Y", value: Binding(get: { Double(settings.area.origin.y) }, set: { settings.area.origin.y = CGFloat($0) }), format: .number) }
            HStack { TextField("Width", value: Binding(get: { Double(settings.area.size.width) }, set: { settings.area.size.width = CGFloat($0) }), format: .number); TextField("Height", value: Binding(get: { Double(settings.area.size.height) }, set: { settings.area.size.height = CGFloat($0) }), format: .number) }
            Button("Select Area…") { RecordingWindows.shared.selectArea { rect in settings.area = rect; if let display = sources.displays.first(where: { $0.frame.contains(rect) }) { settings.sourceID = display.id } } }
        }
    }
}

struct RecordingSessionControls: View {
    @State private var session = RecordingSession.shared
    var body: some View {
        Text(session.document?.displayName ?? "Film").font(.caption).foregroundStyle(.secondary)
        Text(session.project?.name ?? "Recording").font(.headline)
        Text("\(session.phase.rawValue) · \(session.elapsed, specifier: "%.1f")s").monospacedDigit()
        if session.phase == .paused { Button("Resume Recording", systemImage: "play.fill") { session.resume() } }
        else { Button("Pause Recording", systemImage: "pause.fill") { session.pause() }.disabled(!session.canPause) }
        Button("Stop Recording", systemImage: "stop.fill") { Task { await session.stop() } }.disabled(session.phase == .finalizing)
        Button("Show Recording Toolbar", systemImage: "menubar.rectangle") { RecordingWindows.shared.showRecordingToolbar() }
        if session.phase == .paused, let project = session.project, let document = session.document {
            Button("Change Sources…", systemImage: "slider.horizontal.3") { RecordingSetup.shared.open(project: project, document: document, editing: true) }
        }
        if let notice = session.notice { Text(notice).font(.caption) }
        if let error = session.error { Text(error).foregroundStyle(.red) }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
