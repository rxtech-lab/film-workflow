import AppKit
import ApplicationServices
import Carbon

@MainActor final class RecordingInputMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: (CGEvent) -> Void
    private static var mouseDown: (CGPoint, Double, RecordingSource, Int)?
    init(handler: @escaping (CGEvent) -> Void) throws {
        self.handler = handler
        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else { throw RecordingError.message("Enable Input Monitoring for RxFilmStudio to record mouse and keyboard actions.") }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .leftMouseDragged, .rightMouseDragged, .scrollWheel, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<RecordingInputMonitor>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) } }
                else { owner.handler(event) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { throw RecordingError.message("Cannot monitor input. Check Input Monitoring permission.") }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
        Self.mouseDown = nil
    }
    func stop() { if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }; if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }; tap = nil; source = nil }
    static func secureInput() -> Bool {
        let app = AXUIElementCreateSystemWide(); var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success, let value else { return IsSecureEventInputEnabled() }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        var role: CFTypeRef?; AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
        return role as? String == "AXSecureTextField" || IsSecureEventInputEnabled()
    }
    static func shortcut(_ event: CGEvent) -> String? {
        guard event.type == .keyDown, !secureInput(), !event.flags.intersection([.maskCommand, .maskControl]).isEmpty else { return nil }
        let flags = event.flags
        var key = eventText(event).uppercased()
        if key.isEmpty { key = "Key \(event.getIntegerValueField(.keyboardEventKeycode))" }
        return (flags.contains(.maskControl) ? "⌃" : "") + (flags.contains(.maskAlternate) ? "⌥" : "") + (flags.contains(.maskShift) ? "⇧" : "") + (flags.contains(.maskCommand) ? "⌘" : "") + key
    }
    static func eventText(_ event: CGEvent) -> String {
        var length = 0; var chars = [UniChar](repeating: 0, count: 64)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }
    static func action(_ event: CGEvent, time: Double) -> RecordingAction? {
        guard let window = (event.type == .keyDown ? RecordingFocusContext.current() : RecordingFocusContext.window(at: event.location)), window.frame.width > 0, window.frame.height > 0 else { return nil }
        var action = RecordingAction(kind: .move, time: time, duration: 0.02)
        action.bundleID = window.bundleID; action.windowTitle = window.name; action.windowID = window.windowID
        action.x = (event.location.x - window.frame.minX) / window.frame.width; action.y = (event.location.y - window.frame.minY) / window.frame.height
        switch event.type {
        case .mouseMoved: break
        case .leftMouseDown, .rightMouseDown:
            mouseDown = (event.location, time, window, event.type == .rightMouseDown ? 1 : 0); return nil
        case .leftMouseDragged, .rightMouseDragged: return nil
        case .leftMouseUp, .rightMouseUp:
            guard let down = mouseDown else { return nil }; mouseDown = nil
            action.kind = hypot(event.location.x - down.0.x, event.location.y - down.0.y) > 3 ? .drag : .click
            action.time = down.1; action.duration = max(0.02, time - down.1); action.button = down.3
            action.x = (down.0.x - down.2.frame.minX) / down.2.frame.width; action.y = (down.0.y - down.2.frame.minY) / down.2.frame.height
            action.endX = (event.location.x - down.2.frame.minX) / down.2.frame.width; action.endY = (event.location.y - down.2.frame.minY) / down.2.frame.height
            action.windowID = down.2.windowID; action.bundleID = down.2.bundleID; action.windowTitle = down.2.name
        case .scrollWheel:
            action.kind = .scroll; action.duration = 0.12
            action.deltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2); action.deltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        case .keyDown:
            action.kind = secureInput() ? .secureInput : .key
            if action.kind != .secureInput {
                action.keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode)); action.modifiers = event.flags.rawValue
                let text = eventText(event)
                if event.flags.intersection([.maskCommand, .maskControl]).isEmpty, !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { action.kind = .text; action.text = text }
            }
        default: return nil
        }
        if [.click, .drag].contains(action.kind), AXIsProcessTrusted() {
            var element: AXUIElement?
            if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(event.location.x), Float(event.location.y), &element) == .success, let element {
                var identifier: CFTypeRef?; AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier)
                action.accessibilityIdentifier = identifier as? String
            }
        }
        return action
    }
}

@MainActor enum RecordingActionExecutor {
    static func perform(_ action: RecordingAction, session: RecordingSession) async throws {
        guard action.enabled, action.time.isFinite, action.time >= 0, action.duration.isFinite, (0...3600).contains(action.duration), [action.deltaX, action.deltaY].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw RecordingError.message("Invalid action timing or scrolling distance.") }
        switch action.kind {
        case .secureInput: throw RecordingError.message("This action requires secure input. Enter it manually, then replace or disable this step.")
        case .wait:
            session.isWaiting = true; defer { session.isWaiting = false }
            try await delay(action.duration, session: session); return
        case .startCapture, .resumeCapture: session.setCaptureEnabled(true); return
        case .pauseCapture: session.setCaptureEnabled(false); return
        case .changeSource, .changeInputs:
            guard let value = action.settings else { throw RecordingError.message("This action needs recording settings.") }; try await session.changeSettings(value); return
        case .screenshot:
            _ = try await RecordingScreenshotService.capture(windowID: action.windowID, bundleID: action.windowID == nil ? action.bundleID : nil, saveTo: session.document); return
        case .deviceTap, .deviceSwipe, .deviceText:
            try await RecordingDeviceAutomation.shared.perform(action, settings: session.settings); return
        default: break
        }
        session.markExecutionTime(action.id)
        if action.kind == .waitForWindow || action.kind == .waitForElement {
            session.isWaiting = true; defer { session.isWaiting = false }
            let deadline = session.actionClock.elapsed + max(1, action.duration)
            repeat {
                try await session.waitForResume()
                if let _ = try? await target(action), action.kind == .waitForWindow { return }
                if action.kind == .waitForElement, action.accessibilityIdentifier?.isEmpty == false, let _ = try? element(action) { return }
                try await Task.sleep(for: .milliseconds(100))
            } while session.actionClock.elapsed < deadline
            throw RecordingError.message("Timed out waiting for \(action.windowTitle.isEmpty ? action.bundleID : action.windowTitle).")
        }
        let window = try await target(action)
        session.replayTarget = window
        if [.move, .click, .drag, .scroll].contains(action.kind), ![action.x, action.y, action.endX, action.endY].allSatisfy({ $0.isFinite && (0...1).contains($0) }) { throw RecordingError.message("Pointer coordinates must be inside the target window.") }
        if [.key, .text, .click, .drag, .scroll].contains(action.kind) {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == window.bundleID }), let targetWindow = axWindow(window) else { throw RecordingError.message("The target window cannot be focused safely.") }
            app.activate(); guard AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString) == .success else { throw RecordingError.message("Could not focus the target window.") }
            try await delay(0.1, session: session)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw RecordingError.message("The target app did not become focused.") }
        }
        if action.kind == .focus {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == action.bundleID }) else { throw RecordingError.message("Target app is not running.") }
            app.activate(); if let element = axWindow(window) { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }; return
        }
        if action.kind == .positionWindow {
            guard let element = axWindow(window) else { throw RecordingError.message("Target window is not accessible.") }
            var point = CGPoint(x: action.x, y: action.y), size = CGSize(width: action.endX, height: action.endY)
            guard size.width > 0, size.height > 0, let pos = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size), AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos) == .success, AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dimensions) == .success else { throw RecordingError.message("This window cannot be moved or resized.") }; return
        }
        var point = CGPoint(x: window.frame.minX + action.x * window.frame.width, y: window.frame.minY + action.y * window.frame.height)
        if let element = try element(action) {
            var p: CFTypeRef?, s: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p); AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s)
            if let p, let s { var origin = CGPoint.zero, size = CGSize.zero; AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &origin); AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size); point = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2) }
        }
        session.markExecutionTime(action.id)
        switch action.kind {
        case .move: try await move(from: CGEvent(source: nil)?.location ?? point, to: point, duration: action.duration, dragging: false, button: .left, easing: action.easing ?? .easeInOut, session: session)
        case .click, .drag:
            let button: CGMouseButton = action.button == 1 ? .right : .left
            let down: CGEventType = action.button == 1 ? .rightMouseDown : .leftMouseDown
            let up: CGEventType = action.button == 1 ? .rightMouseUp : .leftMouseUp
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
            var end = point
            defer { CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: end, mouseButton: button)?.post(tap: .cghidEventTap) }
            if action.kind == .drag {
                end = CGPoint(x: window.frame.minX + action.endX * window.frame.width, y: window.frame.minY + action.endY * window.frame.height)
                try await move(from: point, to: end, duration: action.duration, dragging: true, button: button, easing: action.easing ?? .easeInOut, session: session)
            }
        case .scroll:
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            let steps = max(1, Int(action.duration * 60)); var previousX = 0, previousY = 0
            for i in 1...steps {
                try await session.waitForResume(); let f = Double(i) / Double(steps), ease = (action.easing ?? .easeInOut).evaluate(f)
                let x = Int((action.deltaX * ease).rounded()), y = Int((action.deltaY * ease).rounded())
                CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(y - previousY), wheel2: Int32(x - previousX), wheel3: 0)?.post(tap: .cghidEventTap)
                previousX = x; previousY = y; try await delay(action.duration / Double(steps), session: session)
            }
        case .key:
            guard (0...127).contains(action.keyCode) else { throw RecordingError.message("Invalid key code.") }
            for down in [true, false] { let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(action.keyCode), keyDown: down); event?.flags = CGEventFlags(rawValue: action.modifiers); event?.post(tap: .cghidEventTap) }
        case .text:
            var chars = Array(action.text.utf16)
            guard chars.count <= 4096 else { throw RecordingError.message("Text action exceeds 4096 UTF-16 characters.") }
            for down in [true, false] { let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down); event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars); event?.post(tap: .cghidEventTap) }
        default: break
        }
    }
    static func delay(_ duration: Double, session: RecordingSession) async throws {
        let end = session.actionClock.elapsed + max(0, duration)
        while session.actionClock.elapsed < end { try Task.checkCancellation(); try await session.waitForResume(); try await Task.sleep(for: .milliseconds(10)) }
    }
    private static func move(from: CGPoint, to: CGPoint, duration: Double, dragging: Bool, button: CGMouseButton, easing: RecordingEasing, session: RecordingSession) async throws {
        let frames = max(1, Int(duration * 60))
        for frame in 1...frames {
            try await session.waitForResume(); let f = Double(frame) / Double(frames), e = easing.evaluate(f)
            let p = CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
            CGEvent(mouseEventSource: nil, mouseType: dragging ? (button == .right ? .rightMouseDragged : .leftMouseDragged) : .mouseMoved, mouseCursorPosition: p, mouseButton: button)?.post(tap: .cghidEventTap)
            try await delay(duration / Double(frames), session: session)
        }
    }
    static func target(_ action: RecordingAction) async throws -> RecordingSource {
        try await RecordingSources.shared.refresh()
        let windows = RecordingSources.shared.windows.filter { action.bundleID.isEmpty || $0.bundleID == action.bundleID }
        if let id = action.windowID, let exact = windows.first(where: { $0.windowID == id }) { return exact }
        let matches = windows.filter { action.windowTitle.isEmpty || $0.name == action.windowTitle || $0.name.hasSuffix(" — " + action.windowTitle) }
        guard matches.count == 1, let window = matches.first else { throw RecordingError.message("Target window is missing or ambiguous. Select the intended window in the movement editor.") }
        return window
    }
    static func axWindow(_ window: RecordingSource) -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == window.bundleID }) else { return nil }
        var value: CFTypeRef?; AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &value)
        let matches = (value as? [AXUIElement] ?? []).filter { element in
            var position: CFTypeRef?, dimensions: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &dimensions)
            guard let position, let dimensions, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID() else { return false }
            var point = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point); AXValueGetValue(unsafeBitCast(dimensions, to: AXValue.self), .cgSize, &size)
            return abs(point.x - window.frame.minX) < 3 && abs(point.y - window.frame.minY) < 3 && abs(size.width - window.frame.width) < 3 && abs(size.height - window.frame.height) < 3
        }
        return matches.count == 1 ? matches.first : nil
    }

    static func element(_ action: RecordingAction) throws -> AXUIElement? {
        guard let identifier = action.accessibilityIdentifier, !identifier.isEmpty else { return nil }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == action.bundleID }) else { throw RecordingError.message("Target app is unavailable.") }
        var count = 0, matches: [AXUIElement] = []
        func find(_ root: AXUIElement, depth: Int) {
            guard depth < 12, count < 500, matches.count < 2 else { return }; count += 1
            var value: CFTypeRef?; AXUIElementCopyAttributeValue(root, kAXIdentifierAttribute as CFString, &value)
            if value as? String == identifier { matches.append(root) }
            AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &value)
            for child in value as? [AXUIElement] ?? [] { find(child, depth: depth + 1) }
        }
        let window = RecordingSources.shared.windows.first { $0.windowID == action.windowID && $0.bundleID == action.bundleID }
        find(window.flatMap(axWindow) ?? AXUIElementCreateApplication(app.processIdentifier), depth: 0)
        guard matches.count == 1 else { throw RecordingError.message("Accessible element \(identifier) is unavailable or ambiguous.") }; return matches[0]
    }
}
