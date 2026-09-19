import AppKit
import AVFoundation
import SwiftData
import VideoEditorCore

@MainActor enum MCPRecordingHandlers {
    private static let specs: [(String, String, [String])] = [
        ("recording_sources", "Discover displays, windows, apps, cameras, microphones, permissions and optional device automation capabilities. Window IDs distinguish duplicate titles; refresh after a target disappears.", []),
        ("recording_focus", "Observe current focused window and last external window with timestamp, bounded accessibility content and an inspectable screenshot. Does not save footage.", []),
        ("recording_screenshot", "Capture one window_id or every capturable window of bundle_id. Returns PNG images and per-window results. save_to_library defaults false; enable only when saving footage is requested. Works idle, recording or paused.", []),
        ("recording_get", "Inspect a recording project, settings, actions, presentation defaults, takes, and active session handle.", ["project_id"]),
        ("recording_configure", "Patch recording project settings. Discover sources first. Settings use sourceKind display/window/area/device, sourceID (legacy single source), selectedWindowIDs (ordered window IDs), cameraIDs, microphoneIDs, audioMode off/selectedApps/allApps, applicationBundleIDs, fps, countdown, showPet, and optional Appium settings.", ["project_id", "settings"]),
        ("recording_start", "Start Record Content or Record Actions using configured settings. Set replay true to execute saved actions and create a new take. Returns an operation handle. Only one session can run across films.", ["project_id"]),
        ("recording_control", "Pause, resume or stop the session by operation_id. Stopping finalizes once; pausing replay suspends execution and media capture. Inspect state for errors and failedActionID.", ["operation_id", "command"]),
        ("recording_actions_edit", "Edit action document. operation is replace, insert, update, delete, duplicate or reorder. Supply actions for replace/insert, action_id and action patch for update, or action_ids for delete/reorder. Reordering retimes actions. Secure input text is never stored. Actual outcomes require replay.", ["project_id", "operation"]),
        ("recording_perform_action", "Perform one structured action in the active session. Requires operation_id. Uses Accessibility targets or window-relative coordinates. Missing or ambiguous targets pause execution. Text actions require explicit user intent.", ["operation_id", "action"]),
        ("recording_presentation", "Patch project presentation defaults or one timeline clip's recording presentation. Supports cursor shape/size/smoothing/clicks, timed visibility, zoom intervals/autoZoom, camera shape/size/X/Y and cameraFollowsZoom. Instance relationships remain independent of clip links.", ["presentation"]),
        ("recording_shortcuts", "Inspect or edit shortcut subtitle cues and text style. Supply project_id for reusable style defaults, or sequence_id and clip_id for a timeline instance. Supply cues with start/end/text to replace timing and visibility, or text_style to patch font, colors, background and position. Ordinary typing is never included automatically.", []),
        ("recording_insert_take", "Insert a take as separate linked tracks with a new recording instance identity. Existing take references are preserved.", ["take_id", "sequence_id"]),
        ("sequence_link_clips", "Link clip_ids as a general edit group. Moving, edge trimming and splitting use atomic validated edits. Set unlink true to unlink their groups without changing presentation.", ["sequence_id", "clip_ids"]),
        ("sequence_track_alias", "Set a track's optional display alias; technical names and UUIDs stay stable. Aliases may repeat.", ["sequence_id", "track_id"]),
        ("recording_pet", "Set optional mood, message and visibility preferences for the camera pet. Session status is controlled by the recorder and cannot be overridden.", ["project_id"])
    ]
    static var descriptors: [MCPToolDescriptor] { specs.map { name, description, required in
        var properties: [String: Any] = [:]
        for key in ["project_id", "sequence_id", "take_id", "clip_id", "track_id", "operation_id", "command", "operation", "action_id", "bundle_id", "alias", "mood", "message"] { properties[key] = ["type": "string"] }
        for key in ["save_to_library", "include_cursor", "replay", "unlink", "visible"] { properties[key] = ["type": "boolean"] }
        for key in ["settings", "presentation", "action", "text_style"] { properties[key] = ["type": "object"] }
        for key in ["action_ids", "clip_ids"] { properties[key] = ["type": "array", "items": ["type": "string"]] }
        properties["actions"] = ["type": "array", "items": ["type": "object"]]
        properties["cues"] = ["type": "array", "items": ["type": "object"]]
        properties["window_id"] = ["type": "integer"]; properties["start"] = ["type": "number"]
        return MCPToolDescriptor(name: name, description: description, inputSchema: ["type": "object", "properties": properties, "required": required, "additionalProperties": false])
    } }
    static func canHandle(_ name: String) -> Bool { specs.contains { $0.0 == name } }
    static func object<T: Encodable>(_ value: T) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])) ?? NSNull() }
    private static func decode<T: Decodable>(_ object: Any, as type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object)) }
    private static func patch<T: Codable>(_ current: T, with fields: [String: Any]) throws -> T {
        guard var merged = object(current) as? [String: Any] else { throw RecordingError.message("Invalid object.") }
        for (key, value) in fields { guard merged.keys.contains(key) || ["windowID", "accessibilityIdentifier", "settings", "referenceImagePath", "actualTime", "easing", "cameraKeyframes", "sourceAspectRatio", "cameraAspectRatio", "screenTransform"].contains(key) else { throw RecordingError.message("Unknown property: \(key)") }; merged[key] = value }
        return try decode(merged, as: T.self)
    }
    private static func uuid(_ args: [String: Any], _ key: String) throws -> UUID { guard let raw = args[key] as? String, let id = UUID(uuidString: raw) else { throw MCPToolError.invalidArguments("Missing or invalid \(key)") }; return id }
    private static func project(_ args: [String: Any], _ context: ModelContext) throws -> ScreenRecordingProject { try MCPLibraryHandlers.fetchRecording(id: uuid(args, "project_id").uuidString, context: context) }
    private static func sequence(_ args: [String: Any], _ context: ModelContext) throws -> SequenceProject { try MCPLibraryHandlers.fetchSequence(id: uuid(args, "sequence_id").uuidString, context: context) }
    static func sessionJSON() -> [String: Any] {
        let s = RecordingSession.shared
        return ["operationID": s.operationID.uuidString, "phase": s.phase.rawValue, "elapsed": s.elapsed, "filmID": s.document?.id.uuidString as Any? ?? NSNull(), "projectID": s.project?.id.uuidString as Any? ?? NSNull(), "error": s.error as Any? ?? NSNull(), "failedActionID": s.failedActionID?.uuidString as Any? ?? NSNull(), "lastTakeID": s.lastTakeID?.uuidString as Any? ?? NSNull()]
    }
    static func handle(name: String, arguments a: [String: Any], context: ModelContext) async throws -> [String: Any] {
        guard let document = ProjectDocumentController.shared.document(forContainer: context.container) else { throw RecordingError.message("Open a film first.") }
        let context = document.container.mainContext
        let session = RecordingSession.shared
        switch name {
        case "recording_sources":
            try await RecordingSources.shared.refresh(); let s = RecordingSources.shared
            return MCPToolRegistry.jsonResult(["displays": object(s.displays), "windows": object(s.windows), "applications": object(s.applications), "cameras": object(s.cameras), "deviceScreens": object(s.deviceScreens), "microphones": object(s.microphones), "permissions": ["screen": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted(), "inputMonitoring": CGPreflightListenEventAccess(), "camera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized, "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized], "physicalDeviceAutomation": RecordingDeviceAutomation.shared.setupInstructions, "session": sessionJSON()])
        case "recording_focus": return try await focusResult()
        case "recording_screenshot":
            let results = try await RecordingScreenshotService.capture(windowID: (a["window_id"] as? NSNumber)?.uint32Value, bundleID: a["bundle_id"] as? String, includeCursor: a["include_cursor"] as? Bool ?? false, saveTo: (a["save_to_library"] as? Bool ?? false) ? document : nil)
            return screenshotResult(results)
        case "recording_get": return MCPToolRegistry.jsonResult(["project": MCPLibraryHandlers.full(.screenRecording(try project(a, context)), context: context), "session": sessionJSON()])
        case "recording_configure":
            let p = try project(a, context)
            let changes = a["settings"] as? [String: Any] ?? [:]
            var settings = try patch(p.settings, with: changes)
            if let sourceID = changes["sourceID"] as? String, changes["selectedWindowIDs"] == nil, settings.sourceKind == .window {
                settings.selectedWindowIDs = sourceID.isEmpty ? [] : [sourceID]
            }
            if settings.sourceKind == .window { settings.selectedWindowIDs = settings.selectedWindowIDs }
            guard [30, 60].contains(settings.fps), [30, 60].contains(settings.cameraFPS), (0...10).contains(settings.countdown) else { throw RecordingError.message("Invalid frame rate or countdown.") }
            if session.isActive { guard session.project?.id == p.id else { throw RecordingError.message("Another project is recording.") }; try await session.changeSettings(settings) }
            p.settings = settings; p.updatedAt = Date(); try context.save()
            return MCPToolRegistry.jsonResult(object(settings))
        case "recording_start":
            try await session.start(project: project(a, context), document: document, replay: a["replay"] as? Bool ?? false); return MCPToolRegistry.jsonResult(sessionJSON())
        case "recording_control", "recording_perform_action":
            guard try uuid(a, "operation_id") == session.operationID, session.document?.id == document.id else { throw RecordingError.message("This session handle is stale or belongs to another film.") }
            if name == "recording_control" {
                switch a["command"] as? String { case "pause": session.pause(); case "resume": session.resume(); case "stop": await session.stop(); default: throw RecordingError.message("Use pause, resume or stop.") }
            } else {
                let action = try patch(RecordingAction(kind: .click), with: a["action"] as? [String: Any] ?? [:])
                do { try await session.waitForResume(); try await RecordingActionExecutor.perform(action, session: session) } catch { session.fail(error); throw error }
            }
            return MCPToolRegistry.jsonResult(sessionJSON())
        case "recording_actions_edit":
            let p = try project(a, context); guard session.project?.id != p.id || session.canEditActions else { throw RecordingError.message("Stop recording before editing its actions. A failed replay action can also be corrected while paused.") }
            var actions = p.actions
            switch a["operation"] as? String {
            case "replace", "insert":
                let incoming = try (a["actions"] as? [[String: Any]] ?? []).map { try patch(RecordingAction(kind: .click), with: $0) }
                if a["operation"] as? String == "replace" { actions = incoming } else { actions += incoming }
            case "update":
                let id = try uuid(a, "action_id"); guard let index = actions.firstIndex(where: { $0.id == id }) else { throw RecordingError.message("Action not found.") }; actions[index] = try patch(actions[index], with: a["action"] as? [String: Any] ?? [:])
            case "delete": let ids = Set(a["action_ids"] as? [String] ?? []); actions.removeAll { ids.contains($0.id.uuidString) }
            case "duplicate": let id = try uuid(a, "action_id"); guard var copy = actions.first(where: { $0.id == id }) else { throw RecordingError.message("Action not found.") }; copy.id = UUID(); copy.time += 0.1; actions.append(copy)
            case "reorder":
                let ids = a["action_ids"] as? [String] ?? []; guard ids.count == actions.count, Set(ids) == Set(actions.map { $0.id.uuidString }) else { throw RecordingError.message("Include every action ID exactly once.") }
                actions = ids.compactMap { id in actions.first { $0.id.uuidString == id } }; var t = 0.0; for i in actions.indices { actions[i].time = t; t += max(0.05, actions[i].duration) }
            default: throw RecordingError.message("Unknown action edit operation.")
            }
            try RecordingActionDocumentService.replace(actions, project: p, document: document, undoManager: NSApp.keyWindow?.undoManager)
            return MCPToolRegistry.jsonResult(object(actions))
        case "recording_insert_take":
            let ids = try RecordingTimelineService.insert(take: RecordingTimelineService.take(id: uuid(a, "take_id"), context: context), into: sequence(a, context), at: a["start"] as? Double ?? 0, undoManager: NSApp.keyWindow?.undoManager); try context.save(); return MCPToolRegistry.jsonResult(["clipIDs": ids.map(\.uuidString)])
        case "recording_shortcuts":
            if a["project_id"] != nil {
                let p = try project(a, context)
                if let value = a["text_style"] as? [String: Any] { p.shortcutStyle = try patch(p.shortcutStyle, with: value); try context.save() }
                return MCPToolRegistry.jsonResult(["textStyle": object(p.shortcutStyle)])
            }
            let sequence = try sequence(a, context), id = try uuid(a, "clip_id")
            var timeline = sequence.timeline
            guard let clip = timeline.clip(id: id), clip.recordingShortcuts != nil else { throw RecordingError.message("Select a recording shortcut track.") }
            var cues = clip.recordingShortcuts ?? [], style = clip.text ?? .caption
            if let value = a["cues"] {
                cues = try decode(value, as: [TextCue].self)
                guard cues.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }) else { throw RecordingError.message("Shortcut timings must be finite and end after their start.") }
            }
            if let value = a["text_style"] as? [String: Any] { style = try patch(style, with: value) }
            if a["cues"] != nil || a["text_style"] != nil {
                try TimelineEditor.update(&timeline, clipID: id) { $0.recordingShortcuts = cues; $0.text = style }
                sequence.editTimeline(timeline, undoManager: NSApp.keyWindow?.undoManager, actionName: "Edit Recording Shortcuts"); try context.save()
            }
            return MCPToolRegistry.jsonResult(["cues": object(cues), "textStyle": object(style)])
        case "sequence_link_clips", "sequence_track_alias", "recording_presentation":
            if name == "recording_presentation", a["project_id"] != nil {
                let p = try project(a, context); p.presentation = try patch(p.presentation, with: a["presentation"] as? [String: Any] ?? [:]); try context.save(); return MCPToolRegistry.jsonResult(object(p.presentation))
            }
            let sequence = try sequence(a, context); var timeline = sequence.timeline
            if name == "sequence_link_clips" {
                let raw = a["clip_ids"] as? [String] ?? []; let ids = Set(raw.compactMap(UUID.init(uuidString:)))
                guard ids.count == raw.count else { throw RecordingError.message("Invalid clip IDs.") }
                if a["unlink"] as? Bool == true { TimelineEditor.unlink(&timeline, clipIDs: ids) } else { try TimelineEditor.link(&timeline, clipIDs: ids) }
            } else if name == "sequence_track_alias" { try TimelineEditor.setTrackAlias(&timeline, trackID: uuid(a, "track_id"), alias: a["alias"] as? String) }
            else {
                let id = try uuid(a, "clip_id"); guard let clip = timeline.clip(id: id), let current = clip.recording else { throw RecordingError.message("Select a recording clip.") }
                let value = try patch(current, with: a["presentation"] as? [String: Any] ?? [:]); try TimelineEditor.update(&timeline, clipID: id) { $0.recording = value }
            }
            sequence.editTimeline(timeline, undoManager: NSApp.keyWindow?.undoManager); try context.save(); return MCPToolRegistry.jsonResult(object(timeline))
        case "recording_pet":
            let p = try project(a, context)
            if let visible = a["visible"] as? Bool { var settings = p.settings; settings.showPet = visible; p.settings = settings; if session.project?.id == p.id { session.settings.showPet = visible } }
            if session.project?.id == p.id { session.petMood = a["mood"] as? String; session.petMessage = (a["message"] as? String).map { String($0.prefix(100)) } }
            try context.save(); return MCPToolRegistry.jsonResult(sessionJSON())
        default: throw MCPToolError.invalidArguments("Unknown recording tool.")
        }
    }
    static func screenshotResult(_ screenshots: [WindowScreenshot]) -> [String: Any] {
        let metadata: [[String: Any]] = screenshots.map { ["windowID": $0.windowID, "title": $0.title, "bundleID": $0.bundleID, "capturedAt": $0.capturedAt.timeIntervalSince1970, "width": $0.width, "height": $0.height, "footageID": $0.footageID?.uuidString as Any? ?? NSNull(), "error": $0.error as Any? ?? NSNull()] }
        var result = MCPToolRegistry.jsonResult(["windows": metadata])
        var content = result["content"] as? [[String: Any]] ?? []
        content += screenshots.compactMap { shot in shot.png.map { ["type": "image", "mimeType": "image/png", "data": $0.base64EncodedString()] } }
        result["content"] = content; return result
    }
    static func focusResult() async throws -> [String: Any] {
        let current = RecordingFocusContext.current(), last = RecordingFocusContext.lastExternalWindow
        let target = current?.bundleID == Bundle.main.bundleIdentifier ? (RecordingSession.shared.replayTarget ?? last) : current
        var result = target?.windowID == nil ? MCPToolRegistry.jsonResult(["windows": []]) : screenshotResult(try await RecordingScreenshotService.capture(windowID: target?.windowID))
        var info = result["structuredContent"] as? [String: Any] ?? [:]
        info["currentFocus"] = current.map(object) ?? NSNull(); info["lastExternalWindow"] = last.map(object) ?? NSNull(); info["observedTarget"] = target.map(object) ?? NSNull(); info["timestamp"] = Date().timeIntervalSince1970
        if let pid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == target?.bundleID })?.processIdentifier { info["accessibility"] = RecordingFocusContext.accessibilityText(pid: pid) }
        result["structuredContent"] = info
        var content = result["content"] as? [[String: Any]] ?? []; content.insert(["type": "text", "text": String(data: try JSONSerialization.data(withJSONObject: info), encoding: .utf8) ?? ""], at: 0); result["content"] = content
        return result
    }
}
