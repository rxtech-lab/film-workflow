import AppKit
import SwiftUI
import RxPet

@MainActor final class RecordingWindows {
    static let shared = RecordingWindows()
    private var toolbar: NSPanel?
    private var editors: [UUID: NSWindow] = [:]
    private var deviceWindow: NSWindow?
    private var areaWindows: [NSWindow] = []
    private let pets = RecordingPetIndicators()
    private let borders = RecordingBorderIndicators()
    private let controls = RecordingControlsOverlay()
    /// Frames seen on the previous follow tick. A target that changed is being
    /// dragged, so its overlays snap instead of animating.
    private var lastTargetFrames: [String: CGRect] = [:]
    /// Recomputed on the slow loop — the window-server scan is the costly part.
    private var frontmostWindowID: String?
    var isToolbarVisible: Bool { toolbar?.isVisible == true }

    func showSetup() {
        if toolbar == nil {
            let panel = RecordingSetupPanel(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 132), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar; panel.hidesOnDeactivate = false
            // Liquid Glass draws the rounded edge. A second AppKit window
            // shadow outlines the rectangular hosting surface around it.
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let hosting = NSHostingView(rootView: RecordingToolbar())
            hosting.focusRingType = .none
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hosting
            toolbar = panel
            panel.orderFrontRegardless()
            RecordingSources.shared.excludedWindowIDs.insert(CGWindowID(panel.windowNumber))
        }
        positionSetup(area: nil)
        toolbar?.makeKeyAndOrderFront(nil)
    }
    func showRecordingToolbar() {
        if toolbar == nil { showSetup() }
        positionSetup(area: nil)
        toolbar?.orderFrontRegardless()
    }
    func positionSetup(area: CGRect?) {
        guard let toolbar else { return }
        let setup = RecordingSetup.shared, session = RecordingSession.shared
        let settings = session.isActive && !setup.isPresented ? session.settings : setup.pending
        let frame = (area ?? (settings.sourceKind == .area ? settings.area : nil)).map(toAppKit)
        let screen = frame.flatMap { area in NSScreen.screens.first { $0.frame.contains(CGPoint(x: area.midX, y: area.midY)) } } ?? toolbar.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let permissionGuide = setup.isPresented && !setup.hasPermissions && session.phase != .preparing
        let stepCount = RecordingPermissions.required(for: settings, replay: setup.replay).count
        let width = min(permissionGuide ? 580.0 : 1100.0, visible.width - 16)
        let listHeight = RecordingSelectedSourcesView.height(count: settings.captureSourceIDs.filter { !$0.isEmpty }.count, width: width - 44)
        let baseHeight: CGFloat = session.phase == .preparing || (session.isActive && !setup.isPresented) ? 104 : 132
        let height = permissionGuide ? CGFloat(250 + stepCount * 110) : baseHeight + (listHeight > 0 ? listHeight + 10 : 0)
        let size = CGSize(width: width, height: min(height, visible.height - 32))
        let target = RecordingSelectionGeometry.toolbarFrame(size: size, area: frame, visibleFrame: visible)
        if toolbar.frame != target { toolbar.setFrame(target, display: true) }
    }
    func prepareCapture(settings: RecordingSettings) {
        showSetup()
        prepareOverlays(settings: settings)
    }
    /// Every overlay window must exist and be registered before capture filters
    /// are built, because `SCContentFilter` freezes its exclusion list at
    /// creation. Anything made later would be burned into the video.
    func prepareOverlays(settings: RecordingSettings) {
        let targets = petTargets
        if settings.showPet { pets.prepare(targets: targets) } else { pets.dismiss() }
        borders.prepare(targets: targets)
        controls.prepare()
    }
    /// Every recorded source. Used for creating overlays and for the border
    /// bars, which mark all of them.
    private var petTargets: [RecordingPetTarget] {
        let session = RecordingSession.shared, sources = RecordingSources.shared
        if session.settings.sourceKind == .device {
            guard let window = deviceWindow else { return [] }
            return [.init(id: session.settings.sourceID, name: "Device Screen", frame: window.frame)]
        }
        return session.settings.captureSourceIDs.compactMap { id in
            guard let frame = session.sourceFrames[id], frame.width > 0, frame.height > 0 else { return nil }
            let name = session.settings.sourceKind == .window ? sources.windows.first { $0.id == id }?.name : sources.displays.first { $0.id == id }?.name
            return RecordingPetTarget(id: id, name: name ?? "Screen", frame: toAppKit(frame))
        }
    }
    func hideToolbar() { toolbar?.orderOut(nil) }
    /// Only the frontmost recorded window carries a companion, so a multi-window
    /// take does not fill the desktop with pets. Every pet still exists — they
    /// are registered with the capture filters — this only governs which shows.
    private var visiblePetTargets: [RecordingPetTarget] {
        let targets = petTargets
        guard RecordingSession.shared.settings.sourceKind == .window, targets.count > 1 else { return targets }
        guard let front = frontmostWindowID, let target = targets.first(where: { $0.id == front }) else { return targets }
        return [target]
    }
    private func refreshFrontmostWindow() {
        let session = RecordingSession.shared
        let ids = Set(session.settings.captureSourceIDs)
        guard session.settings.sourceKind == .window, ids.count > 1 else { frontmostWindowID = ids.first; return }
        if let front = RecordingWindowOrder.frontmost(in: RecordingWindowOrder.rows(), limitedTo: ids) {
            frontmostWindowID = String(front.id)
        }
    }
    /// The pet the controls ride beside: the frontmost window, or — with more
    /// than one recorded display — whichever one holds the cursor.
    private var anchorFrame: CGRect? {
        let targets = visiblePetTargets
        guard targets.count > 1 else { return targets.first.flatMap { pets.placementFrame(for: $0.id) } }
        let cursor = NSEvent.mouseLocation
        let chosen = targets.first { $0.frame.contains(cursor) } ?? targets.first
        return chosen.flatMap { pets.placementFrame(for: $0.id) }
    }
    func updatePet() {
        let session = RecordingSession.shared
        guard session.isActive, session.phase != .finalizing else { pets.hide(); borders.hide(); controls.hide(); return }
        refreshFrontmostWindow()
        // Hiding the toolbar took away the only on-screen place a failure could
        // announce itself, so an error brings it back.
        if session.error != nil, !RecordingSetup.shared.isPresented, !isToolbarVisible { showRecordingToolbar() }
        let targets = visiblePetTargets
        let requiresExclusion = session.settings.sourceKind != .device && session.recordsMedia
        if session.settings.showPet {
            let status: PetStatus = session.error != nil ? .failed : session.phase == .paused ? .paused : session.phase == .preparing ? .preparing : session.isWaiting ? .waiting : session.phase == .replaying ? .replaying : .recording
            pets.update(targets: targets, status: status, mood: session.petMood.flatMap(PetMood.init(rawValue:)), message: session.petMessage,
                        appliedExclusions: session.appliedExclusions, requiresExclusion: requiresExclusion)
        } else { pets.hide() }
        borders.update(targets: petTargets, paused: session.phase == .paused,
                       appliedExclusions: session.appliedExclusions, requiresExclusion: requiresExclusion)
        controls.update(anchor: anchorFrame, appliedExclusions: session.appliedExclusions, requiresExclusion: requiresExclusion)
    }
    /// The fast path: position only, driven by the session's follow loop.
    func updateFollowers() {
        let session = RecordingSession.shared
        guard session.isActive, session.phase != .finalizing else { return }
        let all = petTargets
        var moving: Set<String> = []
        for target in all where lastTargetFrames[target.id] != target.frame {
            if lastTargetFrames[target.id] != nil { moving.insert(target.id) }
            lastTargetFrames[target.id] = target.frame
        }
        if session.settings.showPet { pets.follow(targets: visiblePetTargets, moving: moving) }
        borders.follow(targets: all)
        controls.follow(anchor: anchorFrame)
    }
    func finishPet(success: Bool) {
        borders.hide(); controls.hide()
        pets.finish(success: success)
    }
    func hidePetDuringFilterChange() { pets.hide(); borders.hide(); controls.hide() }
    func dismissOverlays() {
        pets.dismiss(); borders.dismiss(); controls.dismiss()
        lastTargetFrames = [:]; frontmostWindowID = nil
    }
    func showEditor(project: ScreenRecordingProject, document: ProjectDocument) {
        if let window = editors[project.id] { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Recording Movement — \(project.name)"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RecordingActionEditor(project: project, document: document)); window.center(); window.makeKeyAndOrderFront(nil); editors[project.id] = window
    }
    func showDevice(project: ScreenRecordingProject) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Device Control"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RecordingDevicePreview(project: project)); window.center(); window.makeKeyAndOrderFront(nil); deviceWindow = window
        RecordingSources.shared.excludedInputWindowIDs.insert(CGWindowID(window.windowNumber))
    }
    func selectArea(completion: @escaping (CGRect) -> Void) {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver; window.isOpaque = false; window.backgroundColor = .clear; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: RecordingAreaPicker(completion: { rect in
                let global = CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
                completion(self.toCapture(global)); self.areaWindows.forEach { $0.orderOut(nil) }; self.areaWindows = []
            }, cancel: { self.areaWindows.forEach { $0.orderOut(nil) }; self.areaWindows = [] })); window.makeKeyAndOrderFront(nil); areaWindows.append(window)
        }
    }
    private func toAppKit(_ value: CGRect) -> CGRect { CGRect(x: value.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - value.maxY, width: value.width, height: value.height) }
    private func toCapture(_ value: CGRect) -> CGRect { toAppKit(value) }
}

private final class RecordingSetupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        if RecordingSetup.shared.isPresented { RecordingSetup.shared.cancel() }
    }
}

private struct RecordingAreaPicker: View {
    var completion: (CGRect) -> Void
    var cancel: () -> Void
    @State private var selection = CGRect.zero
    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25)
                Text("Drag to select the recording area").padding().background(.regularMaterial).padding(30)
                Rectangle().stroke(.white, lineWidth: 2).background(.blue.opacity(0.12)).frame(width: selection.width, height: selection.height).position(x: selection.midX, y: selection.midY)
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 1).onChanged { value in selection = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y), width: abs(value.translation.width), height: abs(value.translation.height)) }.onEnded { _ in if selection.width > 2 && selection.height > 2 { completion(selection) } })
        }.onExitCommand(perform: cancel)
    }
}
