import SwiftUI

struct RecordingToolbar: View {
    @State private var setup = RecordingSetup.shared
    @State private var session = RecordingSession.shared
    @State private var sources = RecordingSources.shared
    @State private var permissions = RecordingPermissions.shared
    var body: some View {
        GeometryReader { geometry in
          Group {
            if session.phase == .preparing {
                VStack(spacing: 12) {
                    HStack(spacing: 18) {
                        ProgressView().controlSize(.small)
                        Text(session.petMessage ?? "Preparing recording…").font(.headline)
                        Spacer()
                        Button("Cancel", role: .cancel) { setup.cancel() }
                    }
                    selectedSources(settings: session.settings, width: geometry.size.width - 44)
                }.padding(14)
            } else if session.isActive && !setup.isPresented {
                VStack(spacing: 12) {
                    RecordingActiveControls()
                    selectedSources(settings: session.settings, width: geometry.size.width - 44, recording: true)
                }.padding(14)
            } else if !setup.hasPermissions {
                ScrollView {
                    RecordingPermissionGuide(settings: setup.pending, replay: setup.replay)
                    HStack {
                        Button("Cancel", role: .cancel) { setup.cancel() }
                        if !setup.pending.cameraIDs.isEmpty { Button("Remove Camera") { setup.pending.cameraIDs = [] } }
                        if !setup.pending.microphoneIDs.isEmpty { Button("Remove Microphone") { setup.pending.microphoneIDs = [] } }
                        if setup.pending.sourceKind == .device { Button("Record Screen") { setup.choose(.display) } }
                    }.padding(.bottom)
                }
            } else {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Button { setup.cancel() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                            .buttonStyle(.plain).help("Cancel recording setup").accessibilityLabel("Cancel recording setup")
                        Divider().frame(height: 42)
                        ForEach(RecordingSourceKind.allCases, id: \.self) { kind in
                            Button { setup.choose(kind) } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: symbol(kind)).font(.title2)
                                    Text(kind.rawValue.capitalized).font(.caption)
                                }.frame(width: 54, height: 56)
                            }.buttonStyle(.plain)
                                .background(setup.pending.sourceKind == kind ? Color.primary.opacity(0.12) : .clear, in: .rect(cornerRadius: 10))
                                .accessibilityAddTraits(setup.pending.sourceKind == kind ? [.isSelected] : [])
                                .accessibilityIdentifier("recording.source.\(kind.rawValue)")
                        }
                        Divider().frame(height: 42)
                        inputMenu("Camera", symbol: "video", devices: sources.cameras, selection: $setup.pending.cameraIDs)
                        inputMenu("Microphone", symbol: "mic", devices: sources.microphones, selection: $setup.pending.microphoneIDs)
                        Menu {
                            Picker("App Audio", selection: $setup.pending.audioMode) {
                                Text("Off").tag(RecordingAudioMode.off)
                                Text("Selected Apps").tag(RecordingAudioMode.selectedApps)
                                Text("All Apps").tag(RecordingAudioMode.allApps)
                            }
                            if setup.pending.audioMode == .selectedApps {
                                ForEach(sources.applications) { source in Toggle(source.name, isOn: selected(source.id, in: $setup.pending.applicationBundleIDs)) }
                            }
                        } label: { Label(setup.pending.audioMode == .off ? "No App Audio" : "App Audio", systemImage: setup.pending.audioMode == .off ? "speaker.slash" : "speaker.wave.2") }
                        settingsMenu
                        Spacer(minLength: 0)
                        Button(setup.isEditing ? "Apply Changes" : "Start Recording", systemImage: "record.circle") { setup.accept() }
                            .buttonStyle(.glassProminent).tint(.red).disabled(!setup.startControlEnabled)
                            .accessibilityIdentifier("recording.start")
                    }.disabled(setup.isBusy)
                    HStack {
                        targetMenu
                        if let error = setup.error ?? setup.selectionError { Text(error).foregroundStyle(setup.error == nil ? Color.secondary : .red).lineLimit(1).help(error) }
                        Spacer(minLength: 0)
                        Text("⌘⇧Esc to stop").foregroundStyle(.secondary)
                    }.font(.caption)
                    selectedSources(settings: setup.pending, width: geometry.size.width - 44)
                }.padding(14)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .glassEffect(.regular, in: .rect(cornerRadius: 22))
          .padding(8)
        }
        .onExitCommand { if setup.isPresented { setup.cancel() } }
        .onChange(of: setup.pending) { _, _ in setup.updateSelection() }
        .onChange(of: permissions.granted) { _, _ in setup.updateSelection() }
        .onChange(of: session.settings) { _, _ in if session.isActive && !setup.isPresented { RecordingWindows.shared.positionSetup(area: nil) } }
        .onChange(of: session.phase) { _, _ in if session.isActive { RecordingWindows.shared.positionSetup(area: nil) } }
    }
    private func selectedSources(settings: RecordingSettings, width: CGFloat, recording: Bool = false) -> some View {
        RecordingSelectedSourcesView(sources: RecordingSelectedSourcesView.selections(settings: settings, catalog: sources), width: width,
                                     recording: recording, paused: session.phase == .paused,
                                     remove: setup.isPresented && !setup.isBusy && settings.sourceKind == .window ? { setup.toggleWindow($0) } : nil)
    }
    private var settingsMenu: some View {
        Menu {
            Picker("Recording Mode", selection: $setup.pending.mode) {
                Text("Record Content").tag(ScreenRecordingMode.content)
                Text("Record Actions").tag(ScreenRecordingMode.actions)
            }.disabled(setup.isEditing || setup.replay)
            Picker("Frame Rate", selection: $setup.pending.fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
            Picker("Countdown", selection: $setup.pending.countdown) { ForEach(0...10, id: \.self) { Text("\($0) seconds").tag($0) } }
            Toggle("Show Recording Pet", isOn: $setup.pending.showPet)
            Button("Refresh Sources") { Task { do { try await sources.refresh() } catch { setup.error = error.localizedDescription } } }
        } label: { Image(systemName: "gearshape").font(.title3) }.help("Recording settings")
    }
    @ViewBuilder private var targetMenu: some View {
        switch setup.pending.sourceKind {
        case .window:
            Menu("\(setup.pending.selectedWindowIDs.count) windows selected") {
                if sources.windows.isEmpty { Text("No windows available") }
                ForEach(sources.windows) { source in
                    Toggle(source.name, isOn: Binding(get: { setup.pending.selectedWindowIDs.contains(source.id) }, set: { _ in setup.toggleWindow(source.id) }))
                }
            }
        case .display, .area:
            Picker("Display", selection: $setup.pending.sourceID) { ForEach(sources.displays) { Text($0.name).tag($0.id) } }.frame(maxWidth: 300)
        case .device:
            Picker("Device", selection: $setup.pending.sourceID) {
                Text("Choose a device").tag("")
                ForEach(sources.deviceScreens) { Text($0.name).tag($0.id) }
            }.frame(maxWidth: 300)
        }
    }
    private func inputMenu(_ title: String, symbol: String, devices: [RecordingSource], selection: Binding<[String]>) -> some View {
        Menu {
            Button("None") { selection.wrappedValue = [] }
            ForEach(devices) { source in Toggle(source.name, isOn: selected(source.id, in: selection)) }
        } label: {
            Label(selection.wrappedValue.isEmpty ? "No \(title)" : "\(title) (\(selection.wrappedValue.count))", systemImage: selection.wrappedValue.isEmpty ? "\(symbol).slash" : symbol)
                .lineLimit(1)
        }
    }
    private func selected(_ id: String, in ids: Binding<[String]>) -> Binding<Bool> {
        Binding(get: { ids.wrappedValue.contains(id) }, set: { enabled in
            var value = ids.wrappedValue; value.removeAll { $0 == id }; if enabled { value.append(id) }; ids.wrappedValue = value
        })
    }
    private func symbol(_ kind: RecordingSourceKind) -> String {
        switch kind { case .display: "display"; case .window: "macwindow"; case .area: "rectangle.dashed"; case .device: "iphone" }
    }
}
