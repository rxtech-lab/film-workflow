import AppKit

@MainActor final class RecordingSelectionOverlays {
    static let shared = RecordingSelectionOverlays()
    private var windows: [NSWindow] = []
    private var screenFrames: [CGRect] = []
    private var windowSelectionSettings: RecordingSettings?
    private var windowTrackingTimer: Timer?
    private let windowList: () -> [[String: Any]]
    var windowIDs: Set<CGWindowID> { Set(windows.map { CGWindowID($0.windowNumber) }) }
    static var desktopTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    init(windowList: @escaping () -> [[String: Any]] = { RecordingWindowOrder.rows() }) {
        self.windowList = windowList
    }

    func showSetup(settings: RecordingSettings) {
        ensureWindows()
        if settings.sourceKind == .window {
            windowSelectionSettings = settings
            updateWindowSelection()
            if windowTrackingTimer == nil {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.updateWindowSelection() }
                }
                windowTrackingTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            return
        }
        stopWindowTracking()
        for (window, frame) in zip(windows, screenFrames) {
            guard let view = window.contentView as? RecordingSelectionSurface else { continue }
            window.setFrame(frame, display: false)
            view.settings = settings; view.targets = []; view.needsDisplay = true
            // Device setup uses only the toolbar.
            if settings.sourceKind == .device { window.orderOut(nil) } else { window.orderFrontRegardless() }
        }
    }
    private func updateWindowSelection() {
        guard let settings = windowSelectionSettings else { return }
        // An uncatalogued front window must not leave an overlay covering a
        // known window behind it.
        let front = RecordingWindowOrder.frontmost(in: windowList(), excluding: RecordingSources.shared.excludedWindowIDs)
        var target: RecordingSource?
        if let front, var source = RecordingSources.shared.windows.first(where: { $0.id == String(front.id) }) {
            source.frame = front.frame
            target = source
        }
        for (window, screenFrame) in zip(windows, screenFrames) {
            guard let view = window.contentView as? RecordingSelectionSurface else { continue }
            view.settings = settings; view.targets = target.map { [$0] } ?? []
            guard let target else { window.orderOut(nil); continue }
            let frame = RecordingSelectionGeometry.flip(target.frame, desktopTop: Self.desktopTop).intersection(screenFrame)
            guard !frame.isEmpty else { window.orderOut(nil); continue }
            // Only this window intercepts selection clicks. Exposed lower
            // windows receive native clicks and can become the next target.
            window.setFrame(frame, display: false)
            view.needsDisplay = true
            window.orderFrontRegardless()
        }
    }
    private func stopWindowTracking() {
        windowTrackingTimer?.invalidate(); windowTrackingTimer = nil
        windowSelectionSettings = nil
    }
    private func ensureWindows() {
        let screens = NSScreen.screens
        if screenFrames != screens.map(\.frame) || windows.isEmpty {
            dismiss()
            screenFrames = screens.map(\.frame)
            for screen in screens {
                let window = RecordingOverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.level = .floating; window.isOpaque = false; window.backgroundColor = .clear
                window.hasShadow = false; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.contentView = RecordingSelectionSurface(frame: CGRect(origin: .zero, size: screen.frame.size))
                window.orderFrontRegardless()
                windows.append(window)
                RecordingSources.shared.excludedWindowIDs.insert(CGWindowID(window.windowNumber))
            }
        }
    }
    func hide() { stopWindowTracking(); windows.forEach { $0.orderOut(nil) } }
    func dismiss() {
        stopWindowTracking()
        for window in windows {
            RecordingSources.shared.excludedWindowIDs.remove(CGWindowID(window.windowNumber))
            window.orderOut(nil)
        }
        windows = []; screenFrames = []
    }
}

private final class RecordingOverlayWindow: NSPanel {
    // Taking key away from the setup toolbar desaturates its prominent Start
    // button, which reads as disabled for the whole drag. The surface takes
    // clicks through acceptsFirstMouse instead.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RecordingSelectionSurface: NSView {
    var settings = RecordingSettings()
    var targets: [RecordingSource] = []
    private var dragStart = CGPoint.zero
    private var originalArea = CGRect.zero
    private var moving = false
    private var resizeAnchor: CGPoint?
    /// Matches `RecordingSelectionGeometry.validArea`'s minimum, so a drag that
    /// crosses it always produces a recordable rect.
    static let areaDragThreshold: CGFloat = 4
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var captureFrame: CGRect {
        RecordingSelectionGeometry.flip(window?.frame ?? .zero, desktopTop: RecordingSelectionOverlays.desktopTop)
    }
    private func local(_ capture: CGRect) -> CGRect {
        let rect = RecordingSelectionGeometry.flip(capture, desktopTop: RecordingSelectionOverlays.desktopTop)
        return rect.offsetBy(dx: -(window?.frame.minX ?? 0), dy: -(window?.frame.minY ?? 0))
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let p = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        return CGPoint(x: p.x, y: RecordingSelectionOverlays.desktopTop - p.y)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill(); bounds.fill()
        if settings.sourceKind == .area {
            let shade = NSBezierPath(rect: bounds)
            if settings.area.width >= 4 { shade.appendRect(local(settings.area)) }
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(RecordingSelectionStyle.areaShade).setFill(); shade.fill()
            if settings.area.intersects(captureFrame) {
                outline(settings.area, color: .white, label: "\(Int(settings.area.width)) × \(Int(settings.area.height))")
                for p in handles(settings.area) {
                    let rect = local(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                    NSColor.white.setFill(); NSBezierPath(ovalIn: rect).fill()
                }
            } else { label("Drag to select an area · Esc to cancel", in: bounds) }
        } else if settings.sourceKind == .window {
            if let target = targets.first, target.frame.intersects(captureFrame) {
                let selected = settings.selectedWindowIDs.contains(target.id)
                NSColor.systemBlue.withAlphaComponent(selected ? 0.22 : 0.12).setFill()
                NSBezierPath(roundedRect: local(target.frame).insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
                outline(target.frame, color: .systemBlue.withAlphaComponent(selected ? 1 : 0.65), label: "\(selected ? "✓" : "+")  \(target.name)")
            }
        } else if settings.sourceKind == .display {
            let selected = RecordingSources.shared.displays.first { $0.id == settings.sourceID }?.frame.intersects(captureFrame) == true
            let shade = RecordingSelectionStyle.displayShade(selected: selected)
            if shade > 0 { NSColor.black.withAlphaComponent(shade).setFill(); bounds.fill() }
            // A darkened display must not also wear a bright frame competing
            // with the selected one.
            let tint = (selected ? NSColor.systemBlue : .white).withAlphaComponent(RecordingSelectionStyle.displayOutlineAlpha(selected: selected))
            outline(captureFrame.insetBy(dx: 3, dy: 3), color: tint, label: selected ? "Selected display" : "Click to select this display")
        }
    }
    private func outline(_ frame: CGRect, color: NSColor, label text: String?) {
        let rect = local(frame).insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        color.setStroke(); path.lineWidth = 3; path.stroke()
        if let text { label(text, in: rect) }
    }
    private func label(_ text: String, in frame: CGRect) {
        let visibleFrame = frame.intersection(bounds)
        let available = bounds.insetBy(dx: 16, dy: 16)
        guard !visibleFrame.isEmpty, !available.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let display = text as NSString
        let size = display.size(withAttributes: attributes)
        let width = min(ceil(size.width) + 48, min(560, max(240, visibleFrame.width - 32)), available.width)
        let height = ceil(size.height) + 32
        let card = CGRect(
            x: max(available.minX, min(visibleFrame.midX - width / 2, available.maxX - width)),
            y: max(available.minY, min(visibleFrame.midY - height / 2, available.maxY - height)),
            width: width, height: height
        )
        let path = NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        shadow.set()
        NSColor(calibratedWhite: 0.1, alpha: 0.96).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.2).setStroke(); path.lineWidth = 1; path.stroke()
        display.draw(in: card.insetBy(dx: 24, dy: 16), withAttributes: attributes)
    }
    private func handles(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }
    override func mouseDown(with event: NSEvent) {
        guard !RecordingSetup.shared.isBusy else { return }
        let p = point(event), setup = RecordingSetup.shared
        if settings.sourceKind == .window {
            if let target = targets.first(where: { $0.frame.contains(p) }) { setup.toggleWindow(target.id) }
        } else if settings.sourceKind == .display {
            if let display = RecordingSources.shared.displays.first(where: { $0.frame.contains(p) }) {
                setup.pending.sourceID = display.id
                // A press on a display is both a selection and the start of a
                // possible area drag; which one it was is settled on mouse-up.
                dragStart = p; originalArea = .zero; resizeAnchor = nil; moving = false
                setup.beginAreaDrag(displayID: display.id)
                setup.updateSelection()
            }
        } else if settings.sourceKind == .area {
            dragStart = p; originalArea = settings.area; resizeAnchor = nil
            if let handle = handles(originalArea).first(where: { hypot($0.x - p.x, $0.y - p.y) < 12 }) {
                resizeAnchor = CGPoint(x: handle.x == originalArea.minX ? originalArea.maxX : originalArea.minX, y: handle.y == originalArea.minY ? originalArea.maxY : originalArea.minY)
            }
            moving = resizeAnchor == nil && originalArea.contains(p)
            setup.beginAreaDrag(displayID: RecordingSources.shared.displays.first { $0.frame.contains(p) }?.id ?? "")
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard [.area, .display].contains(settings.sourceKind), !RecordingSetup.shared.isBusy else { return }
        let p = point(event)
        // From display mode a click needs room to stay a click; only a real
        // drag becomes an area.
        if settings.sourceKind == .display,
           hypot(p.x - dragStart.x, p.y - dragStart.y) < Self.areaDragThreshold { return }
        let frame = captureFrame
        var rect: CGRect
        if moving {
            rect = originalArea.offsetBy(dx: p.x - dragStart.x, dy: p.y - dragStart.y)
            rect.origin.x = max(frame.minX, min(rect.minX, frame.maxX - rect.width))
            rect.origin.y = max(frame.minY, min(rect.minY, frame.maxY - rect.height))
        } else { rect = RecordingSelectionGeometry.drag(from: resizeAnchor ?? dragStart, to: p, within: frame) }
        RecordingSetup.shared.updateAreaDrag(rect)
    }
    override func mouseUp(with event: NSEvent) {
        RecordingSetup.shared.endAreaDrag()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { RecordingSetup.shared.cancel() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { RecordingSetup.shared.cancel() }
}
