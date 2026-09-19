import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import SwiftData
import VideoEditorCore

@MainActor @Observable final class RecordingSession {
    static let shared = RecordingSession()
    enum Phase: String { case idle, preparing, recording, recordingActions, replaying, paused, finalizing, failed }
    private(set) var phase: Phase = .idle
    private(set) var elapsed: Double = 0
    private(set) var operationID = UUID()
    private(set) var project: ScreenRecordingProject?
    private(set) var document: ProjectDocument?
    var settings = RecordingSettings()
    var error: String?
    var notice: String?
    var petMessage: String?
    var petMood: String?
    private(set) var failedActionID: UUID?
    private(set) var lastTakeID: UUID?
    var isActive: Bool { ![.idle, .failed].contains(phase) }
    var recordsMedia: Bool { settings.mode == .content || isReplaying }
    var canPause: Bool { [.recording, .recordingActions, .replaying].contains(phase) }
    var canEditActions: Bool { !isActive || (phase == .paused && failedActionID != nil) }
    var targetFrame: CGRect = .zero
    var replayTarget: RecordingSource?
    var isWaiting = false
    var audioLevels: [String: Double] = [:]
    func previewSession(id: String) -> AVCaptureSession? { devices.first { $0.deviceID == id }?.session }
    private(set) var appliedExclusions: Set<CGWindowID> = []
    let clock = RecordingClock()
    let actionClock = RecordingClock()
    private var directory: URL?
    private var screens: [String: RecordingScreenStream] = [:]
    private(set) var sourceFrames: [String: CGRect] = [:]
    private var pointersBySource: [String: [RecordingPointerSample]] = [:]
    private var endingWindows = Set<String>()
    private var devices: [RecordingDeviceCapture] = []
    private var taps: [RecordingAudioTap] = []
    private var outputs: [(RecordingComponent, RecordingMediaWriter)] = []
    private var pointer: [RecordingPointerSample] = []
    private var shortcuts: [TextCue] = []
    private var actions: [RecordingAction] = []
    private var timerTask: Task<Void, Never>?
    /// Visual follow runs far faster than the bookkeeping loop so the pet and
    /// the recording bar keep up with a window the user is dragging.
    private var followTask: Task<Void, Never>?
    /// The frames last written into a component's recorded `geometry`, kept
    /// apart from `sourceFrames` because the fast loop mutates that one.
    private var sampledFrames: [String: CGRect] = [:]
    private var replayTask: Task<Void, Never>?
    private var inputMonitor: RecordingInputMonitor?
    private var previousPhase: Phase = .recording
    private var replayIndex = 0
    private var replayActions: [RecordingAction] = []
    private var replayOffset: Double = 0
    private var audioFingerprint: [String: [UInt32]] = [:]
    private var isStopping = false
    private var isReplaying = false
    private var observedWindow: RecordingSource?
    private var secureStepRecorded = false
    private var lastReferenceTime: Double = -10
    private var captureEnabled = true
    private var completedActionIDs: Set<UUID> = []
    private var needsCaptureRestart = false
    private var isChangingCapture = false
    private var resumeTask: Task<Void, Never>?
    private var hasStarted = false
    private var isStarting = false
    private var isStartingMedia = false

    func start(project: ScreenRecordingProject, document: ProjectDocument, replay: Bool = false) async throws {
        guard !isActive, !isStopping, !isStarting else { throw RecordingError.message("Another recording session is active.") }
        isStarting = true; defer { isStarting = false }
        self.project = project; self.document = document; settings = project.settings
        directory = nil; notice = nil; sourceFrames = [:]; sampledFrames = [:]; pointersBySource = [:]; endingWindows = []
        clock.reset(); clock.pause(); actionClock.reset(); actionClock.pause()
        guard [30, 60].contains(settings.fps), (0...10).contains(settings.countdown) else { throw RecordingError.message("Choose 30 or 60 fps and a countdown between 0 and 10 seconds.") }
        operationID = UUID(); error = nil; phase = .preparing; elapsed = 0; lastTakeID = nil
        needsCaptureRestart = false; appliedExclusions = []; petMessage = nil; hasStarted = false
        isReplaying = replay; captureEnabled = true; completedActionIDs = []; observedWindow = nil; secureStepRecorded = false; pointer = []; shortcuts = []; actions = []; outputs = []; replayIndex = 0; replayOffset = 0; failedActionID = nil
        do {
            guard CGPreflightScreenCaptureAccess(), CGPreflightListenEventAccess() else { throw RecordingError.message("Complete Screen Recording and Input Monitoring setup before recording.") }
            await RecordingInputPreviewStore.shared.stopAll()
            try await RecordingSources.shared.refresh()
            if !settings.cameraIDs.isEmpty || settings.sourceKind == .device {
                guard await AVCaptureDevice.requestAccess(for: .video) else { throw RecordingError.message("Allow camera access in System Settings to record cameras or devices.") }
            }
            if !settings.microphoneIDs.isEmpty || settings.sourceKind == .device {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecordingError.message("Allow microphone access in System Settings.") }
            }
            guard phase == .preparing, !Task.isCancelled else { throw CancellationError() }
            guard CGPreflightScreenCaptureAccess(), CGPreflightListenEventAccess() else { throw RecordingError.message("Complete Screen Recording and Input Monitoring setup before recording.") }
            if replay, !AXIsProcessTrusted() { throw RecordingError.message("Enable Accessibility access for RxFilmStudio in System Settings before replaying.") }
            let directory = document.packageURL.appendingPathComponent("Media/ScreenRecordings/\(project.id)/\(operationID)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); self.directory = directory
            if replay, settings.sourceKind == .device { RecordingWindows.shared.showDevice(project: project) }
            try resolveSourceFrames()
            RecordingWindows.shared.prepareCapture(settings: settings)
            RecordingSelectionOverlays.shared.hide()
            try await RecordingSources.shared.refresh()
            for count in stride(from: settings.countdown, to: 0, by: -1) {
                guard phase == .preparing, !Task.isCancelled else { throw CancellationError() }
                petMessage = "Starting in \(count)…"; try await Task.sleep(for: .seconds(1))
            }
            guard phase == .preparing, !Task.isCancelled else { throw CancellationError() }
            inputMonitor = try RecordingInputMonitor { [weak self] event in self?.recordInput(event) }
            clock.reset(); actionClock.reset()
            if settings.mode == .content || replay { try await startMedia() }
            guard phase == .preparing, !Task.isCancelled else { throw CancellationError() }
            phase = replay ? .replaying : (settings.mode == .actions ? .recordingActions : .recording)
            hasStarted = true
            RecordingSetup.shared.recordingStarted()
            // The controls now ride beside the pet; the wide toolbar would only
            // sit on top of what is being recorded.
            RecordingWindows.shared.hideToolbar()
            if let event = CGEvent(source: nil) { recordInput(event) }
            petMessage = nil
            timerTask = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    self.observeSourceGeometry()
                    self.observeFocus()
                    self.elapsed = self.settings.mode == .actions && !self.isReplaying ? self.actionClock.elapsed : self.clock.elapsed
                    RecordingWindows.shared.updatePet()
                    tick += 1
                    if tick % 20 == 0 {
                        self.checkpoint()
                        if self.settings.audioMode != .off && !self.clock.isPaused && self.phase != .recordingActions {
                            do { try self.refreshAudioTaps() } catch { self.fail(error) }
                        }
                    }
                }
            }
            followTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    guard !Task.isCancelled, let self else { return }
                    self.followSourceGeometry()
                    RecordingWindows.shared.updateFollowers()
                }
            }
            if replay {
                replayActions = project.actions.filter(\.enabled).sorted { $0.time < $1.time }
                runReplay()
            }
        } catch is CancellationError {
            await stop(); error = nil; phase = .idle
        } catch {
            self.error = error.localizedDescription
            await stop(); phase = .failed
            throw error
        }
    }

    private func newOutput(role: RecordingComponent.Role, name: String, sourceID: String, video: Bool) throws -> RecordingMediaWriter {
        guard let directory, let document else { throw RecordingError.message("No recording destination.") }
        let url = directory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = RecordingMediaWriter(url: url, video: video, clock: clock)
        writer.nominalFrameDuration = 1 / Double(role == .camera ? settings.cameraFPS : settings.fps)
        writer.onFailure = { [weak self] message in Task { @MainActor [weak self] in self?.captureFailed(message) } }
        if !video { writer.onLevel = { [weak self] level in Task { @MainActor [weak self] in self?.audioLevels[sourceID] = level } } }
        let catalog = RecordingSources.shared
        let candidates = role == .screen ? (settings.sourceKind == .window ? catalog.windows : settings.sourceKind == .device ? catalog.deviceScreens : catalog.displays) : role == .camera ? catalog.cameras : catalog.microphones
        let source = candidates.first { $0.id == sourceID }
        let geometry = source.map { [RecordingGeometryEvent(time: clock.elapsed, frame: $0.frame)] }
        outputs.append((RecordingComponent(role: role, name: name, filePath: document.storage.relativePath(for: url) ?? "", sourceID: sourceID, sourceIdentity: source, geometry: geometry), writer))
        return writer
    }
    private func startMedia() async throws {
        isStartingMedia = true; defer { isStartingMedia = false }
        guard isActive, phase != .finalizing, !Task.isCancelled else { throw CancellationError() }
        if settings.sourceKind == .device {
            let writer = try newOutput(role: .screen, name: "Device Screen", sourceID: settings.sourceID, video: true)
            let deviceInfo = AVCaptureDevice(uniqueID: settings.sourceID)
            let deviceAudio = deviceInfo?.hasMediaType(.audio) == true || deviceInfo?.hasMediaType(.muxed) == true ? try newOutput(role: .deviceAudio, name: "Device Audio", sourceID: settings.sourceID, video: false) : nil
            let device = try RecordingDeviceCapture(deviceID: settings.sourceID, writer: writer, fps: settings.fps, audioWriter: deviceAudio)
            configureFailure(device); devices.append(device); await device.start()
        } else {
            for id in settings.captureSourceIDs {
                var target = settings; target.sourceID = id
                let (filter, frame) = try RecordingSources.shared.filter(for: target)
                sourceFrames[id] = frame
                let config = SCStreamConfiguration()
                let scale = Double(filter.pointPixelScale)
                config.width = max(2, Int(frame.width * scale) / 2 * 2); config.height = max(2, Int(frame.height * scale) / 2 * 2)
                config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(settings.fps)); config.showsCursor = false; config.capturesAudio = false
                config.queueDepth = 5; config.captureDynamicRange = .SDR; config.colorSpaceName = CGColorSpace.sRGB; config.pixelFormat = kCVPixelFormatType_32BGRA
                if settings.sourceKind == .area {
                    guard let display = RecordingSources.shared.content?.displays.first(where: { String($0.displayID) == id }), RecordingSelectionGeometry.validArea(settings.area, in: display.frame) else { throw RecordingError.message("Choose a valid recording area.") }
                    config.sourceRect = settings.area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                }
                let name = RecordingSources.shared.windows.first { $0.id == id && settings.sourceKind == .window }?.name ?? "Screen"
                let writer = try newOutput(role: .screen, name: name, sourceID: id, video: true)
                let capture = try RecordingScreenStream(filter: filter, configuration: config, writer: writer)
                capture.onFailure = { [weak self] message in Task { @MainActor [weak self] in self?.screenFailed(id: id, message: message) } }
                screens[id] = capture
                try await capture.stream.startCapture()
                guard isActive, phase != .finalizing, !Task.isCancelled else { throw CancellationError() }
            }
            appliedExclusions = Set(RecordingSources.shared.content?.windows.map(\.windowID) ?? []).intersection(RecordingSources.shared.excludedWindowIDs)
        }
        for id in Set(settings.cameraIDs) {
            guard isActive, phase != .finalizing, !Task.isCancelled else { throw CancellationError() }
            let writer = try newOutput(role: .camera, name: AVCaptureDevice(uniqueID: id)?.localizedName ?? "Camera", sourceID: id, video: true)
            let capture = try RecordingDeviceCapture(deviceID: id, writer: writer, fps: settings.cameraFPS); configureFailure(capture); devices.append(capture); await capture.start()
        }
        for id in Set(settings.microphoneIDs) {
            guard isActive, phase != .finalizing, !Task.isCancelled else { throw CancellationError() }
            let writer = try newOutput(role: .microphone, name: AVCaptureDevice(uniqueID: id)?.localizedName ?? "Microphone", sourceID: id, video: false)
            let capture = try RecordingDeviceCapture(deviceID: id, writer: writer); configureFailure(capture); devices.append(capture); await capture.start()
        }
        try refreshAudioTaps()
    }
    private func refreshAudioTaps() throws {
        guard settings.audioMode != .off else { return }
        let raw = RecordingAudioTap.processes()
        let roots = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier).sorted { $0.count > $1.count }
        var all: [String: [UInt32]] = [:]
        for (bundle, processes) in raw { let app = roots.first { bundle == $0 || bundle.hasPrefix($0 + ".") } ?? bundle; all[app, default: []] += processes }
        for key in all.keys { all[key]?.sort() }
        let selected = settings.audioMode == .allApps ? all : all.filter { bundle, _ in settings.applicationBundleIDs.contains { bundle == $0 || bundle.hasPrefix($0 + ".") } }
        guard selected != audioFingerprint || taps.isEmpty else { return }
        let wasPaused = clock.isPaused; clock.pause(); defer { if !wasPaused { clock.resume() } }
        for tap in taps { tap.stop() }; taps = []
        audioFingerprint = selected
        for (bundle, processes) in selected.sorted(by: { $0.key < $1.key }) {
            let name = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundle }?.localizedName ?? bundle
            let writer = try newOutput(role: .applicationAudio, name: name, sourceID: bundle, video: false)
            taps.append(try RecordingAudioTap(processes: processes, excluding: false, writer: writer))
        }
        if settings.audioMode == .allApps {
            let writer = try newOutput(role: .systemAudio, name: "System Audio", sourceID: "system", video: false)
            taps.append(try RecordingAudioTap(processes: selected.values.flatMap { $0 }, excluding: true, writer: writer))
        }
    }
    func pause() {
        guard canPause else { return }; previousPhase = phase; phase = .paused; clock.pause(); actionClock.pause()
    }
    func resume() {
        guard phase == .paused, resumeTask == nil else { return }
        if needsCaptureRestart {
            resumeTask = Task { [weak self] in
                guard let self else { return }; defer { resumeTask = nil }
                do { try await changeSettings(settings); try Task.checkCancellation(); needsCaptureRestart = false; completeResume() }
                catch is CancellationError { }
                catch { fail(error) }
            }
        } else { completeResume() }
    }
    private func completeResume() {
        guard phase == .paused else { return }; error = nil; phase = previousPhase; if captureEnabled { clock.resume() }; actionClock.resume()
        if isReplaying, replayTask == nil {
            replayActions = (project?.actions ?? []).filter { $0.enabled && !completedActionIDs.contains($0.id) }.sorted { $0.time < $1.time }
            replayIndex = 0; replayOffset = max(0, actionClock.elapsed - (replayActions.first?.time ?? actionClock.elapsed)); failedActionID = nil; runReplay()
        }
    }
    func setCaptureEnabled(_ enabled: Bool) { captureEnabled = enabled; if enabled && phase != .paused { clock.resume() } else { clock.pause() } }
    func changeSettings(_ value: RecordingSettings) async throws {
        guard isActive, phase != .finalizing, !isChangingCapture else { throw RecordingError.message("The recording is unavailable or already changing sources.") }
        isChangingCapture = true; defer { isChangingCapture = false }
        guard value.mode == settings.mode else { throw RecordingError.message("Stop recording before changing recording modes.") }
        if phase == .recordingActions || (phase == .paused && previousPhase == .recordingActions) {
            settings = value; try await RecordingSources.shared.refresh()
            try resolveSourceFrames()
            RecordingWindows.shared.prepareOverlays(settings: value)
            var action = RecordingAction(kind: .changeSource, time: actionClock.elapsed); action.settings = value; actions.append(action); return
        }
        RecordingWindows.shared.hidePetDuringFilterChange()
        clock.pause()
        let oldScreens = Array(screens.values); screens = [:]
        for screen in oldScreens { screen.onFailure = nil; try? await screen.stream.stopCapture() }
        for device in devices { await device.stop() }; devices = []
        for tap in taps { tap.stop() }; taps = []; audioFingerprint = [:]
        for (_, writer) in outputs { writer.endSegment() }
        settings = value
        try await RecordingSources.shared.refresh()
        try resolveSourceFrames()
        RecordingWindows.shared.prepareOverlays(settings: value)
        // New overlay windows must be enumerated before building exclusion filters.
        try await RecordingSources.shared.refresh()
        if captureEnabled && phase != .paused { clock.resume() }
        do { try await startMedia(); needsCaptureRestart = false } catch { needsCaptureRestart = true; fail(error); throw error }
    }
    private func configureFailure(_ device: RecordingDeviceCapture) {
        device.onFailure = { [weak self] message in Task { @MainActor [weak self] in self?.captureFailed(message) } }
    }
    private func captureFailed(_ message: String) {
        guard isActive, phase != .finalizing, !isChangingCapture else { return }
        needsCaptureRestart = true; fail(RecordingError.message(message))
    }
    func fail(_ error: Error) {
        self.error = error.localizedDescription
        if canPause { pause() }
        RecordingSelectionOverlays.shared.hide()
        checkpoint()
    }
    func stop() async {
        if isStopping {
            while isStopping { try? await Task.sleep(for: .milliseconds(20)); await Task.yield() }
            return
        }
        guard phase != .idle else { return }
        isStopping = true; phase = .finalizing
        clock.pause(); actionClock.pause()
        resumeTask?.cancel()
        while isChangingCapture || isStartingMedia { try? await Task.sleep(for: .milliseconds(20)); await Task.yield() }
        resumeTask = nil
        replayTask?.cancel(); replayTask = nil; timerTask?.cancel(); timerTask = nil; followTask?.cancel(); followTask = nil
        inputMonitor?.stop(); inputMonitor = nil
        let oldScreens = Array(screens.values); screens = [:]
        for screen in oldScreens { screen.onFailure = nil; try? await screen.stream.stopCapture() }
        for device in devices { await device.stop() }; devices = []
        for tap in taps { tap.stop() }; taps = []; audioFingerprint = [:]
        clock.pause(); actionClock.pause()
        do {
            if let project, let document {
                if settings.mode == .actions && !isReplaying {
                    if hasStarted { try RecordingActionDocumentService.replace(actions, project: project, document: document, undoManager: nil, name: "Record Actions") }
                } else {
                    var components: [RecordingComponent] = []
                    for (var component, writer) in outputs {
                        do {
                            if let result = try await writer.finish() {
                                component.start = result.start; component.duration = result.duration; component.width = result.width; component.height = result.height
                                var presentation = project.presentation; presentation.pointer = component.role == .screen ? pointersBySource[component.sourceID] ?? pointer : pointer; presentation.timeOffset = component.start; presentation.sourceAspectRatio = Double(component.width) / Double(max(1, component.height))
                                if component.role == .camera { presentation.role = .camera; component.presentation = presentation }
                                if component.role == .screen { presentation.role = .screen; component.presentation = presentation }
                                components.append(component)
                            }
                        } catch { self.error = error.localizedDescription }
                    }
                    if !components.isEmpty {
                        let take = RecordingTake(name: "\(project.name) · Take \(project.takes.count + 1)")
                        take.operationID = operationID
                        take.duration = clock.elapsed; take.isInterrupted = error != nil; take.project = project
                        if let directory, let path = try RecordingTimelineService.writeTransparentPixel(directory: directory, storage: document.storage) {
                            components += RecordingComponentBuilder.cursors(for: components, path: path, defaults: project.presentation)
                        }
                        components.append(.init(role: .shortcuts, name: "Shortcuts", filePath: "", duration: take.duration, cues: shortcuts))
                        take.components = components; take.actionsData = try JSONEncoder().encode(actions)
                        document.container.mainContext.insert(take); project.updatedAt = Date(); try document.container.mainContext.save(); lastTakeID = take.id
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
        phase = error == nil ? .idle : .failed; checkpoint(); outputs = []; isStopping = false
        RecordingWindows.shared.hideToolbar(); RecordingSelectionOverlays.shared.dismiss()
        RecordingSetup.shared.sessionEnded()
        RecordingWindows.shared.finishPet(success: error == nil)
    }
    private func checkpoint() {
        guard let directory else { return }
        guard let project else { return }
        let components = outputs.map { component, writer in
            var component = component
            if let (start, duration, width, height) = writer.snapshot() { component.start = start; component.duration = duration; component.width = width; component.height = height }
            return component
        }
        let value = RecordingCheckpoint(operationID: operationID, projectID: project.id, phase: phase.rawValue, elapsed: clock.elapsed, settings: settings, actions: actions, components: components, pointer: pointer, shortcuts: shortcuts, takeID: lastTakeID, pointersBySource: pointersBySource)
        do { try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("Session.json"), options: .atomic) }
        catch { self.error = "Could not checkpoint recording: \(error.localizedDescription)" }
    }
    private func recordInput(_ event: CGEvent) {
        guard phase != .preparing, phase != .finalizing else { return }
        if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53, event.flags.contains([.maskCommand, .maskShift]) { Task { await stop() }; return }
        guard canPause, !clock.isPaused else { return }
        let position = event.location
        if event.type == .keyDown, let window = RecordingFocusContext.current(), let id = window.windowID, RecordingSources.shared.excludedInputWindowIDs.contains(id) { return }
        if event.type != .keyDown, RecordingSources.shared.excludesInput(at: position) { return }
        let visibleWindow = settings.sourceKind == .window ? RecordingFocusContext.window(at: position)?.id : nil
        for (id, frame) in sourceFrames where frame.width > 0 && frame.height > 0 {
            let occluded = settings.sourceKind == .window && visibleWindow != id
            let x = occluded ? -1 : (position.x - frame.minX) / frame.width, y = occluded ? -1 : (position.y - frame.minY) / frame.height
            guard x.isFinite, y.isFinite else { continue }
            let clicked = (0...1).contains(x) && (0...1).contains(y) && [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
            if clicked || pointersBySource[id]?.last.map({ clock.elapsed - $0.time > 1.0 / 60 }) != false {
                pointersBySource[id, default: []].append(.init(time: clock.elapsed, x: x, y: y, clicked: clicked))
            }
        }
        pointer = pointersBySource[settings.captureSourceIDs.first ?? ""] ?? []
        if let cue = RecordingInputMonitor.shortcut(event) { shortcuts.append(.init(start: clock.elapsed, end: clock.elapsed + 1.5, text: cue)) }
        if settings.mode == .actions, !isReplaying, let action = RecordingInputMonitor.action(event, time: actionClock.elapsed) {
            actions.append(action)
            if [.click, .focus].contains(action.kind), action.time - lastReferenceTime > 1, let directory {
                lastReferenceTime = action.time
                Task { [weak self] in
                    guard let self, let data = try? await RecordingScreenshotService.capture(windowID: action.windowID).first?.png else { return }
                    let url = directory.appendingPathComponent("reference-\(action.id).png")
                    do { try data.write(to: url, options: .atomic); if let index = actions.firstIndex(where: { $0.id == action.id }) { actions[index].referenceImagePath = document?.storage.relativePath(for: url) } } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
    /// The fast path. Frames only — no recorded samples, no teardown decisions.
    /// A transient `CGWindowList` miss at 30 Hz must never end a stream, so a
    /// missing window is left for `observeSourceGeometry` to adjudicate.
    private func followSourceGeometry() {
        guard settings.sourceKind == .window, phase != .finalizing else { return }
        for id in settings.selectedWindowIDs {
            guard let frame = windowFrame(id) else { continue }
            sourceFrames[id] = frame
        }
        targetFrame = settings.captureSourceIDs.first.flatMap { sourceFrames[$0] } ?? .zero
    }
    /// The bookkeeping path: device health, closed windows, and the recorded
    /// geometry track. Sampling stays on this slower loop deliberately — these
    /// events are renderer input written into every take, so their density is
    /// decoupled from how smoothly the overlays follow.
    private func observeSourceGeometry() {
        if canPause, devices.contains(where: { AVCaptureDevice(uniqueID: $0.deviceID)?.isConnected != true }) {
            captureFailed("A camera, microphone, or connected device became unavailable.")
        }
        guard settings.sourceKind == .window, phase != .finalizing else { return }
        for id in settings.selectedWindowIDs {
            guard let frame = windowFrame(id) else { endWindow(id); continue }
            sourceFrames[id] = frame
            if sampledFrames[id] != frame {
                sampledFrames[id] = frame
                if let index = outputs.lastIndex(where: { $0.0.role == .screen && $0.0.sourceID == id }) {
                    var geometry = outputs[index].0.geometry ?? []
                    geometry.append(.init(time: clock.elapsed, frame: frame)); outputs[index].0.geometry = geometry
                }
            }
        }
        targetFrame = settings.captureSourceIDs.first.flatMap { sourceFrames[$0] } ?? .zero
    }
    private func windowFrame(_ id: String) -> CGRect? {
        guard let number = UInt32(id) else { return nil }
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]] ?? []
        return (rows.first?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }
    private func screenFailed(id: String, message: String) {
        guard screens[id] != nil, !isChangingCapture, phase != .finalizing else { return }
        if settings.sourceKind == .window, windowFrame(id) == nil { endWindow(id) }
        else { captureFailed(message) }
    }
    private func endWindow(_ id: String) {
        guard settings.selectedWindowIDs.contains(id), endingWindows.insert(id).inserted else { return }
        let capture = screens.removeValue(forKey: id)
        capture?.onFailure = nil; capture?.writer.endSegment()
        sourceFrames.removeValue(forKey: id); sampledFrames.removeValue(forKey: id)
        settings.selectedWindowIDs = settings.selectedWindowIDs.filter { $0 != id }
        let name = outputs.first { $0.0.role == .screen && $0.0.sourceID == id }?.0.name ?? "Window"
        notice = "\(name) closed. \(settings.selectedWindowIDs.isEmpty ? "Saving the take." : "Other windows are still recording.")"
        let operation = operationID
        Task {
            if let capture { try? await capture.stream.stopCapture() }
            guard operationID == operation else { return }
            endingWindows.remove(id)
            if settings.sourceKind == .window, settings.selectedWindowIDs.isEmpty { await stop() }
        }
    }
    private func resolveSourceFrames() throws {
        sourceFrames = [:]; sampledFrames = [:]
        guard settings.sourceKind != .device else { targetFrame = .zero; return }
        guard !settings.captureSourceIDs.isEmpty else { throw RecordingError.message("Select at least one window.") }
        for id in settings.captureSourceIDs {
            var value = settings; value.sourceID = id
            sourceFrames[id] = try RecordingSources.shared.filter(for: value).1
        }
        targetFrame = settings.captureSourceIDs.first.flatMap { sourceFrames[$0] } ?? .zero
    }
    private func observeFocus() {
        let window = RecordingFocusContext.current()
        guard phase == .recordingActions else { return }
        if let id = window?.windowID, RecordingSources.shared.excludedInputWindowIDs.contains(id) { return }
        if RecordingInputMonitor.secureInput() {
            if !secureStepRecorded { var action = RecordingAction(kind: .secureInput, time: actionClock.elapsed); action.bundleID = window?.bundleID ?? ""; action.windowID = window?.windowID; actions.append(action); secureStepRecorded = true }
        } else { secureStepRecorded = false }
        guard let window else { return }
        if observedWindow?.windowID != window.windowID {
            var action = RecordingAction(kind: .focus, time: actionClock.elapsed, duration: 0.1)
            action.bundleID = window.bundleID; action.windowTitle = window.name; action.windowID = window.windowID; actions.append(action)
        } else if observedWindow?.frame != window.frame {
            var action = RecordingAction(kind: .positionWindow, time: actionClock.elapsed, duration: 0.1)
            action.bundleID = window.bundleID; action.windowID = window.windowID; action.windowTitle = window.name
            action.x = window.frame.minX; action.y = window.frame.minY; action.endX = window.frame.width; action.endY = window.frame.height; actions.append(action)
        }
        observedWindow = window
    }
    private func runReplay() {
        replayTask = Task { [weak self] in
            guard let self else { return }
            while replayIndex < replayActions.count && !Task.isCancelled {
                let action = replayActions[replayIndex]
                do {
                    while (phase == .paused || actionClock.elapsed < action.time + replayOffset) && !Task.isCancelled { try await Task.sleep(for: .milliseconds(20)) }
                    try Task.checkCancellation()
                    let before = actionClock.elapsed
                    var executed = action; executed.actualTime = clock.elapsed; actions.append(executed)
                    try await RecordingActionExecutor.perform(action, session: self)
                    replayOffset += max(0, actionClock.elapsed - before - action.duration)
                    completedActionIDs.insert(action.id); replayIndex += 1
                } catch is CancellationError { return }
                catch { failedActionID = action.id; fail(error); replayTask = nil; return }
            }
            if !Task.isCancelled { replayTask = nil; await stop() }
        }
    }
    func markExecutionTime(_ id: UUID) {
        if let index = actions.lastIndex(where: { $0.id == id }) { actions[index].actualTime = clock.elapsed }
    }
    func appendDeviceAction(_ action: RecordingAction) {
        guard phase == .recordingActions else { return }
        var action = action; action.time = actionClock.elapsed; actions.append(action)
    }
    func waitForResume() async throws {
        while phase == .paused { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(20)) }
        guard phase != .finalizing, phase != .idle, phase != .failed else { throw CancellationError() }
    }
}
