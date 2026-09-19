import AppKit
import SwiftData

@MainActor @Observable final class RecordingSetup {
    static let shared = RecordingSetup()
    private(set) var isPresented = false
    private(set) var isEditing = false
    private(set) var isBusy = false
    /// True from the mouse-down that starts an area drag until its mouse-up.
    /// Keeps the Start button looking live and stops the toolbar walking around
    /// under the cursor while the rect is still being dragged out.
    private(set) var isAdjustingArea = false
    /// What the drag started from, so an abandoned drag can put it back.
    private var areaDragOriginKind: RecordingSourceKind?
    private(set) var project: ScreenRecordingProject?
    private(set) var document: ProjectDocument?
    private(set) var replay = false
    var pending = RecordingSettings()
    var error: String?
    private var refreshTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    var hasPermissions: Bool { RecordingPermissions.shared.allows(pending, replay: replay) }
    var selectionError: String? {
        let sources = RecordingSources.shared
        switch pending.sourceKind {
        case .window:
            if pending.selectedWindowIDs.isEmpty { return "Select at least one window." }
            if pending.selectedWindowIDs.contains(where: { id in !sources.windows.contains { $0.id == id } }) { return "A selected window is unavailable. Update your selection." }
        case .display, .area:
            guard let display = sources.displays.first(where: { $0.id == pending.sourceID }) else { return "Choose a display." }
            if pending.sourceKind == .area, !RecordingSelectionGeometry.validArea(pending.area, in: display.frame) { return "Drag on a display to select a recording area." }
        case .device:
            if !sources.deviceScreens.contains(where: { $0.id == pending.sourceID }) { return "Choose a connected device." }
        }
        if pending.cameraIDs.contains(where: { id in !sources.cameras.contains { $0.id == id } }) { return "A selected camera is disconnected." }
        if pending.microphoneIDs.contains(where: { id in !sources.microphones.contains { $0.id == id } }) { return "A selected microphone is disconnected." }
        if pending.audioMode == .selectedApps, pending.applicationBundleIDs.isEmpty { return "Choose an app for audio capture." }
        return nil
    }
    var canStart: Bool { isPresented && !isBusy && hasPermissions && selectionError == nil }
    /// A drag in flight keeps the record button looking armed even while the
    /// half-dragged rect is still too small to record. Starting is still gated
    /// on `canStart`; this only governs appearance.
    var startControlEnabled: Bool { canStart || isAdjustingArea }

    @discardableResult
    func openQuickRecording(in document: ProjectDocument) throws -> ScreenRecordingProject {
        guard !RecordingSession.shared.isActive, !isBusy else { throw RecordingError.message("Another recording session is active.") }
        if isPresented, let project {
            RecordingWindows.shared.showSetup()
            return project
        }
        let context = document.container.mainContext
        var descriptor = FetchDescriptor<ScreenRecordingProject>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        let project: ScreenRecordingProject
        if let existing = try context.fetch(descriptor).first {
            project = existing
        } else {
            project = ScreenRecordingProject(name: String(localized: "Screen Recording"))
            context.insert(project)
            do { try context.save() } catch { context.delete(project); throw error }
        }
        open(project: project, document: document)
        pending.mode = .content
        return project
    }

    func open(project: ScreenRecordingProject, document: ProjectDocument, replay: Bool = false, editing: Bool = false) {
        guard !isBusy else { return }
        if isPresented { RecordingWindows.shared.showSetup(); return }
        let session = RecordingSession.shared
        guard !session.isActive || (editing && session.phase == .paused && session.project?.id == project.id) else { return }
        self.project = project; self.document = document; self.replay = replay
        isEditing = editing; pending = editing ? session.settings : project.settings
        error = nil; isPresented = true
        RecordingPermissions.shared.refresh()
        RecordingWindows.shared.showSetup()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPresented else { return }
                RecordingPermissions.shared.refresh()
                if RecordingPermissions.shared.baseGranted && !self.isBusy {
                    do {
                        try await RecordingSources.shared.refresh()
                        guard !Task.isCancelled, self.isPresented else { return }
                        if self.pending.sourceID.isEmpty, [.display, .area].contains(self.pending.sourceKind) {
                            self.pending.sourceID = RecordingSources.shared.displays.first?.id ?? ""
                        }
                        self.updateSelection()
                    } catch { self.error = error.localizedDescription }
                } else if !self.hasPermissions { RecordingSelectionOverlays.shared.dismiss() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func choose(_ kind: RecordingSourceKind) {
        guard !isBusy else { return }
        isAdjustingArea = false; areaDragOriginKind = nil
        let windows = pending.selectedWindowIDs
        pending.sourceKind = kind
        switch kind {
        case .window: pending.selectedWindowIDs = windows
        case .display, .area:
            if !RecordingSources.shared.displays.contains(where: { $0.id == pending.sourceID }) { pending.sourceID = RecordingSources.shared.displays.first?.id ?? "" }
        case .device:
            if !RecordingSources.shared.deviceScreens.contains(where: { $0.id == pending.sourceID }) { pending.sourceID = RecordingSources.shared.deviceScreens.first?.id ?? "" }
        }
        updateSelection()
    }
    func toggleWindow(_ id: String) {
        guard !isBusy else { return }
        var ids = pending.selectedWindowIDs
        if ids.contains(id) { ids.removeAll { $0 == id } } else { ids.append(id) }
        pending.selectedWindowIDs = ids
        updateSelection()
    }
    func beginAreaDrag(displayID: String) {
        guard !isBusy else { return }
        areaDragOriginKind = pending.sourceKind
        isAdjustingArea = true
        if !displayID.isEmpty { pending.sourceID = displayID }
    }
    /// A drag on a display becomes an area selection, so the existing area
    /// handles, crop and toolbar placement all take over from here.
    func updateAreaDrag(_ rect: CGRect) {
        guard !isBusy, isAdjustingArea else { return }
        if pending.sourceKind != .area { pending.sourceKind = .area }
        pending.area = rect
        updateSelection()
    }
    func endAreaDrag() {
        guard isAdjustingArea else { return }
        isAdjustingArea = false
        // A click with a little jitter, or a drag abandoned below the minimum,
        // must not strand the user in area mode with a red error where they
        // only meant to pick a display.
        if selectionError != nil, areaDragOriginKind == .display {
            pending.sourceKind = .display
            pending.area = .zero
        }
        areaDragOriginKind = nil
        updateSelection()
    }
    func updateSelection() {
        guard isPresented, !isBusy else { return }
        if hasPermissions { RecordingSelectionOverlays.shared.showSetup(settings: pending) }
        else { RecordingSelectionOverlays.shared.dismiss() }
        // Mid-drag the toolbar would chase the rect around under the cursor.
        // It settles once on mouse-up instead.
        guard !isAdjustingArea else { return }
        RecordingWindows.shared.positionSetup(area: pending.sourceKind == .area ? pending.area : nil)
    }
    func accept() {
        RecordingPermissions.shared.refresh()
        guard canStart, let project, let document else { return }
        isBusy = true; error = nil
        let value = pending, editing = isEditing
        startTask = Task {
            defer { isBusy = false; startTask = nil }
            do {
                try await RecordingSources.shared.refresh()
                try Task.checkCancellation()
                guard selectionError == nil, hasPermissions else { throw RecordingError.message(selectionError ?? "Complete permission setup before recording.") }
                if editing {
                    try await RecordingSession.shared.changeSettings(value)
                    project.settings = value; try document.container.mainContext.save()
                    dismiss(keepToolbar: true)
                } else {
                    let old = project.settings
                    project.settings = value
                    do { try document.container.mainContext.save() } catch { project.settings = old; throw error }
                    try await RecordingSession.shared.start(project: project, document: document, replay: replay)
                }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                if !isPresented { isPresented = true; RecordingWindows.shared.showSetup() }
            }
        }
    }
    func cancel() {
        guard !(isEditing && isBusy) else { return }
        startTask?.cancel()
        if RecordingSession.shared.phase == .preparing { Task { await RecordingSession.shared.stop() } }
        dismiss(keepToolbar: isEditing)
    }
    func recordingStarted() { dismiss(keepToolbar: true) }
    func sessionEnded() {
        if isEditing, isPresented { dismiss() }
    }
    private func dismiss(keepToolbar: Bool = false) {
        isPresented = false
        isAdjustingArea = false; areaDragOriginKind = nil
        refreshTask?.cancel(); refreshTask = nil
        // The toolbar stays only while preparing — it owns the countdown and the
        // permission guide. Once recording begins the pet-side panel takes over.
        if keepToolbar, RecordingSession.shared.isActive, RecordingSession.shared.phase == .preparing {
            RecordingWindows.shared.showRecordingToolbar()
        }
        else { RecordingWindows.shared.hideToolbar() }
        RecordingSelectionOverlays.shared.dismiss()
        Task { await RecordingInputPreviewStore.shared.stopAll() }
    }
}

nonisolated enum RecordingSelectionGeometry {
    static func flip(_ rect: CGRect, desktopTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
    }
    static func validArea(_ rect: CGRect, in display: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width >= 4 && rect.height >= 4 && display.contains(rect)
    }
    static func drag(from start: CGPoint, to end: CGPoint, within frame: CGRect) -> CGRect {
        let a = CGPoint(x: min(frame.maxX, max(frame.minX, start.x)), y: min(frame.maxY, max(frame.minY, start.y)))
        let b = CGPoint(x: min(frame.maxX, max(frame.minX, end.x)), y: min(frame.maxY, max(frame.minY, end.y)))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    static func toolbarFrame(size: CGSize, area: CGRect?, visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(size.width, visibleFrame.width - 16), height: size.height)
        var origin = CGPoint(x: (area?.midX ?? visibleFrame.midX) - size.width / 2, y: visibleFrame.minY + 28)
        if let area, area.width > 0 {
            origin.y = area.minY - size.height - 12
            if origin.y < visibleFrame.minY + 8 { origin.y = area.maxY + 12 }
        }
        origin.x = max(visibleFrame.minX + 8, min(origin.x, visibleFrame.maxX - size.width - 8))
        origin.y = max(visibleFrame.minY + 8, min(origin.y, visibleFrame.maxY - size.height - 8))
        return CGRect(origin: origin, size: size)
    }
}

/// Shades the selection overlays paint. Kept here so the values are assertable
/// without rendering, and so every surface draws the same selection language.
nonisolated enum RecordingSelectionStyle {
    /// Everything outside the chosen area dims to this.
    static let areaShade: CGFloat = 0.28
    /// An unselected display dims hard enough to read as "not this one" while
    /// staying legible enough to aim at. The selected display gets no wash.
    static func displayShade(selected: Bool) -> CGFloat { selected ? 0 : 0.6 }
    /// The selected display owns the bright outline; the others recede.
    static func displayOutlineAlpha(selected: Bool) -> CGFloat { selected ? 1 : 0.55 }
}
