import AppKit
@preconcurrency import AVFoundation
import CoreMediaIO
@preconcurrency import ScreenCaptureKit
import SwiftData

/// Front-to-back window-server order, shared by selection highlighting and by
/// the recording overlays that only follow the topmost recorded window.
nonisolated enum RecordingWindowOrder {
    static func rows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    }
    /// The frontmost normal, visible window, optionally restricted to a set of
    /// ids. `rows` must be in the window server's front-to-back order.
    static func frontmost(in rows: [[String: Any]], excluding excluded: Set<CGWindowID> = [],
                          limitedTo ids: Set<String>? = nil) -> (id: CGWindowID, frame: CGRect)? {
        for row in rows {
            guard let id = row[kCGWindowNumber as String] as? UInt32, !excluded.contains(id),
                  row[kCGWindowLayer as String] as? Int == 0,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 1, frame.height > 1 else { continue }
            if let ids, !ids.contains(String(id)) { continue }
            return (id, frame)
        }
        return nil
    }
}

nonisolated struct RecordingSource: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var kind: String
    var bundleID: String = ""
    var windowID: UInt32?
    var frame: CGRect = .zero
}

@MainActor @Observable final class RecordingSources {
    static let shared = RecordingSources()
    var displays: [RecordingSource] = []
    var windows: [RecordingSource] = []
    var cameras: [RecordingSource] = []
    var microphones: [RecordingSource] = []
    var deviceScreens: [RecordingSource] = []
    var error: String?
    private(set) var content: SCShareableContent?
    var excludedWindowIDs: Set<CGWindowID> = []
    var excludedInputWindowIDs: Set<CGWindowID> = []
    // Pet panels pass clicks through during capture. Their
    // bounds must not suppress the real mouse events underneath them.
    var passThroughWindowIDs: Set<CGWindowID> = [] {
        didSet { inputRegionsUpdated = .distantPast }
    }
    private var inputRegions: [CGRect] = []
    private var inputRegionsUpdated = Date.distantPast
    func excludesInput(at point: CGPoint) -> Bool {
        if Date().timeIntervalSince(inputRegionsUpdated) > 0.05 {
            let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            inputRegions = rows.compactMap { row in
                guard let id = row[kCGWindowNumber as String] as? UInt32, !passThroughWindowIDs.contains(id), excludedWindowIDs.contains(id) || excludedInputWindowIDs.contains(id),
                      (row[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                      let bounds = row[kCGWindowBounds as String] as? NSDictionary else { return nil }
                return CGRect(dictionaryRepresentation: bounds)
            }
            inputRegionsUpdated = Date()
        }
        return inputRegions.contains { $0.contains(point) }
    }
    var applications: [RecordingSource] {
        Dictionary(grouping: windows.filter { !$0.bundleID.isEmpty }, by: \.bundleID).map { id, values in
            RecordingSource(id: id, name: NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }?.localizedName ?? values[0].name, kind: "application", bundleID: id)
        }.sorted { $0.name < $1.name }
    }
    func refresh() async throws {
        var allow: UInt32 = 1
        var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOHardwarePropertyAllowScreenCaptureDevices), mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
        _ = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices.map {
            RecordingSource(id: $0.uniqueID, name: $0.localizedName, kind: "camera")
        }
        deviceScreens = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices.map { RecordingSource(id: $0.uniqueID, name: $0.localizedName, kind: "device") }
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices.map {
            RecordingSource(id: $0.uniqueID, name: $0.localizedName, kind: "microphone")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        self.content = content
        displays = content.displays.map { .init(id: String($0.displayID), name: "Display \($0.displayID) — \($0.width)×\($0.height)", kind: "display", frame: $0.frame) }
        windows = content.windows.filter { $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 && !excludedWindowIDs.contains($0.windowID) }.map {
            .init(id: String($0.windowID), name: "\($0.owningApplication?.applicationName ?? "App") — \($0.title ?? "Untitled")", kind: "window", bundleID: $0.owningApplication?.bundleIdentifier ?? "", windowID: $0.windowID, frame: $0.frame)
        }.sorted { $0.name < $1.name }
        error = nil
    }
    func filter(for settings: RecordingSettings) throws -> (SCContentFilter, CGRect) {
        guard let content else { throw RecordingError.message("Refresh recording sources first.") }
        if settings.sourceKind == .window {
            guard let id = UInt32(settings.sourceID), let window = content.windows.first(where: { $0.windowID == id }), !excludedWindowIDs.contains(id) else { throw RecordingError.message("The selected window is unavailable.") }
            return (SCContentFilter(desktopIndependentWindow: window), window.frame)
        }
        guard let display = content.displays.first(where: { String($0.displayID) == settings.sourceID }) ?? (settings.sourceID.isEmpty ? content.displays.first : nil) else { throw RecordingError.message("The selected display is unavailable.") }
        let excluded = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
        return (SCContentFilter(display: display, excludingWindows: excluded), settings.sourceKind == .area ? settings.area : display.frame)
    }
    func requestScreenAccess() { _ = CGRequestScreenCaptureAccess() }
}

nonisolated enum RecordingError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

nonisolated struct WindowScreenshot: Sendable {
    var windowID: UInt32
    var title: String
    var bundleID: String
    var png: Data?
    var width: Int = 0
    var height: Int = 0
    var capturedAt = Date()
    var footageID: UUID?
    var error: String?
}

@MainActor enum RecordingScreenshotService {
    static func capture(windowID: UInt32? = nil, bundleID: String? = nil, includeCursor: Bool = false, saveTo document: ProjectDocument? = nil) async throws -> [WindowScreenshot] {
        try await RecordingSources.shared.refresh()
        guard windowID != nil || bundleID?.isEmpty == false else { throw RecordingError.message("Choose a window ID or application bundle ID.") }
        let targets = RecordingSources.shared.content?.windows.filter {
            !RecordingSources.shared.excludedWindowIDs.contains($0.windowID) && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 && (windowID == nil || $0.windowID == windowID) && (bundleID == nil || $0.owningApplication?.bundleIdentifier == bundleID)
        } ?? []
        guard !targets.isEmpty else { throw RecordingError.message("No capturable windows match this target.") }
        var results: [WindowScreenshot] = []
        for window in targets {
            var result = WindowScreenshot(windowID: window.windowID, title: window.title ?? "Window", bundleID: window.owningApplication?.bundleIdentifier ?? "")
            do {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                config.width = max(2, Int(filter.contentRect.width * Double(filter.pointPixelScale)))
                config.height = max(2, Int(filter.contentRect.height * Double(filter.pointPixelScale)))
                config.showsCursor = includeCursor
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw RecordingError.message("Could not encode screenshot.") }
                result.png = data; result.width = image.width; result.height = image.height
                if let document {
                    let directory = document.packageURL.appendingPathComponent("Media/Screenshots", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent(UUID().uuidString + ".png")
                    try data.write(to: url, options: .atomic)
                    let asset = ImportedAsset(name: "\(window.owningApplication?.applicationName ?? "App") — \(result.title)", kind: .image, originalPath: "")
                    asset.relativePath = document.storage.relativePath(for: url); asset.width = image.width; asset.height = image.height
                    asset.captureMetadata = try JSONSerialization.data(withJSONObject: ["windowID": result.windowID, "bundleID": result.bundleID, "title": result.title, "capturedAt": result.capturedAt.timeIntervalSince1970])
                    document.container.mainContext.insert(asset); try document.container.mainContext.save(); result.footageID = asset.id
                }
            } catch { result.error = error.localizedDescription }
            results.append(result)
        }
        return results
    }
}

@MainActor enum RecordingFocusContext {
    private(set) static var lastExternalWindow: RecordingSource?
    static func window(at point: CGPoint) -> RecordingSource? {
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        for row in rows where row[kCGWindowLayer as String] as? Int == 0 {
            guard let id = row[kCGWindowNumber as String] as? UInt32, !RecordingSources.shared.excludedWindowIDs.contains(id),
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point),
                  let pid = row[kCGWindowOwnerPID as String] as? Int32, let app = NSRunningApplication(processIdentifier: pid) else { continue }
            return RecordingSource(id: String(id), name: row[kCGWindowName as String] as? String ?? app.localizedName ?? "Window", kind: "window", bundleID: app.bundleIdentifier ?? "", windowID: id, frame: frame)
        }
        return nil
    }
    static func current() -> RecordingSource? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let match = windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 && !RecordingSources.shared.excludedWindowIDs.contains($0[kCGWindowNumber as String] as? UInt32 ?? 0) }
        guard let row = match, let id = row[kCGWindowNumber as String] as? UInt32 else { return nil }
        let bounds = (row[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
        let result = RecordingSource(id: String(id), name: row[kCGWindowName as String] as? String ?? app.localizedName ?? "Window", kind: "window", bundleID: app.bundleIdentifier ?? "", windowID: id, frame: bounds)
        if app.processIdentifier != ProcessInfo.processInfo.processIdentifier { lastExternalWindow = result }
        return result
    }
    static func accessibilityText(pid: pid_t, limit: Int = 12000) -> String {
        guard AXIsProcessTrusted() else { return "Accessibility access is unavailable." }
        let root = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &focused) == .success, let focused else { return "" }
        var output = "", count = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 8, count < 180, output.count < limit else { return }; count += 1
            var role: CFTypeRef?; AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
            if role as? String == "AXSecureTextField" { return }
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let string = value as? String, !string.isEmpty { output += String(string.prefix(300)) + "\n" }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success, let children = children as? [AXUIElement] { for child in children { walk(child, depth: depth + 1) } }
        }
        walk(unsafeBitCast(focused, to: AXUIElement.self), depth: 0)
        return String(output.prefix(limit))
    }
}
