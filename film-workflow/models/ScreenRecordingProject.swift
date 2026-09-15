import CoreGraphics
import Foundation
import SwiftData
import VideoEditorCore

nonisolated enum ScreenRecordingMode: String, Codable, CaseIterable, Sendable { case content, actions }
nonisolated enum RecordingSourceKind: String, Codable, CaseIterable, Sendable { case display, window, area, device }
nonisolated enum RecordingAudioMode: String, Codable, CaseIterable, Sendable { case off, selectedApps, allApps }

nonisolated struct RecordingSettings: Codable, Hashable, Sendable {
    var mode: ScreenRecordingMode = .content
    var sourceKind: RecordingSourceKind = .display
    var sourceID: String = ""
    // Optional storage keeps settings written before multi-window capture readable.
    private var windowSelection: [String]?
    var selectedWindowIDs: [String] {
        get { windowSelection ?? (sourceKind == .window && !sourceID.isEmpty ? [sourceID] : []) }
        set {
            var seen = Set<String>()
            windowSelection = newValue.filter { !$0.isEmpty && seen.insert($0).inserted }
            if sourceKind == .window { sourceID = windowSelection?.first ?? "" }
        }
    }
    var captureSourceIDs: [String] { sourceKind == .window ? selectedWindowIDs : [sourceID] }
    private enum CodingKeys: String, CodingKey {
        case mode, sourceKind, sourceID, windowSelection = "selectedWindowIDs", area
        case cameraIDs, microphoneIDs, audioMode, applicationBundleIDs, fps, cameraFPS, countdown, showPet
        case deviceAutomationURL, deviceUDID, deviceAppBundleID
    }
    var area: CGRect = .zero
    var cameraIDs: [String] = []
    var microphoneIDs: [String] = []
    var audioMode: RecordingAudioMode = .off
    var applicationBundleIDs: [String] = []
    var fps: Int = 60
    var cameraFPS: Int = 30
    var countdown: Int = 3
    var showPet: Bool = true
    var deviceAutomationURL: String = "http://127.0.0.1:4723"
    var deviceUDID: String = ""
    var deviceAppBundleID: String = ""
}

nonisolated enum RecordingEasing: String, Codable, CaseIterable, Sendable {
    case linear, easeIn, easeOut, easeInOut
    func evaluate(_ value: Double) -> Double { let t = min(1, max(0, value)); switch self { case .linear: return t; case .easeIn: return t * t; case .easeOut: return 1 - (1 - t) * (1 - t); case .easeInOut: return t * t * (3 - 2 * t) } }
}
nonisolated struct RecordingAction: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case move, click, drag, scroll, key, text, focus, positionWindow, wait, waitForWindow, waitForElement
        case startCapture, pauseCapture, resumeCapture, changeSource, changeInputs, screenshot, secureInput
        case deviceTap, deviceSwipe, deviceText
    }
    var id = UUID()
    var kind: Kind
    var time: Double = 0
    var duration: Double = 0.3
    var enabled = true
    var x: Double = 0.5
    var y: Double = 0.5
    var endX: Double = 0.5
    var endY: Double = 0.5
    var deltaX: Double = 0
    var deltaY: Double = 0
    var button: Int = 0
    var keyCode: Int = 0
    var modifiers: UInt64 = 0
    var text: String = ""
    var bundleID: String = ""
    var windowTitle: String = ""
    var windowID: UInt32?
    var accessibilityIdentifier: String?
    var settings: RecordingSettings?
    var referenceImagePath: String?
    var actualTime: Double?
    var easing: RecordingEasing?
}

nonisolated struct RecordingGeometryEvent: Codable, Hashable, Sendable {
    var time: Double
    var frame: CGRect
    var orientationDegrees: Double = 0
}
nonisolated struct RecordingComponent: Codable, Identifiable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case screen, camera, microphone, applicationAudio, systemAudio, deviceAudio, cursor, shortcuts }
    var id = UUID()
    var role: Role
    var name: String
    var filePath: String
    var start: Double = 0
    var duration: Double = 0
    var width: Int = 0
    var height: Int = 0
    var sourceID: String = ""
    var cues: [TextCue] = []
    var presentation: RecordingClipPresentation?
    var sourceIdentity: RecordingSource?
    var geometry: [RecordingGeometryEvent]?
    var sourceKind: SourceKind {
        switch role {
        case .screen, .camera: .video
        case .cursor: .image
        case .shortcuts: .captions
        default: .audio
        }
    }
}

@Model final class ScreenRecordingProject: GroupableProject {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var groupID: UUID?
    var settingsData: Data = Data()
    var actionsData: Data = Data()
    var presentationData: Data = Data()
    var shortcutStyleData: Data = Data()
    @Relationship(deleteRule: .cascade, inverse: \RecordingTake.project) var takes: [RecordingTake] = []
    var visibleTakes: [RecordingTake] { takes.filter { !$0.isRemovedFromLibrary } }
    init(name: String) { self.name = name }
    var settings: RecordingSettings {
        get { (try? JSONDecoder().decode(RecordingSettings.self, from: settingsData)) ?? RecordingSettings() }
        set { if let data = try? JSONEncoder().encode(newValue) { settingsData = data; updatedAt = Date() } }
    }
    var actions: [RecordingAction] {
        get { (try? JSONDecoder().decode([RecordingAction].self, from: actionsData)) ?? [] }
        set { if let data = try? JSONEncoder().encode(newValue) { actionsData = data; updatedAt = Date() } }
    }
    var presentation: RecordingClipPresentation {
        get { (try? JSONDecoder().decode(RecordingClipPresentation.self, from: presentationData)) ?? .init() }
        set { if let data = try? JSONEncoder().encode(newValue) { presentationData = data; updatedAt = Date() } }
    }
    var shortcutStyle: TextStyle {
        get { (try? JSONDecoder().decode(TextStyle.self, from: shortcutStyleData)) ?? .caption }
        set { if let data = try? JSONEncoder().encode(newValue) { shortcutStyleData = data; updatedAt = Date() } }
    }
}

@Model final class RecordingTake {
    var id: UUID = UUID()
    var formatVersion: Int = 1
    var operationID: UUID?
    var createdAt: Date = Date()
    var name: String
    var duration: Double = 0
    var componentsData: Data = Data()
    var actionsData: Data = Data()
    var isInterrupted: Bool = false
    // Timeline sources continue resolving removed takes and their components.
    var isRemovedFromLibrary: Bool = false
    var project: ScreenRecordingProject?
    init(name: String) { self.name = name }
    var components: [RecordingComponent] {
        get { (try? JSONDecoder().decode([RecordingComponent].self, from: componentsData)) ?? [] }
        set { if let data = try? JSONEncoder().encode(newValue) { componentsData = data } }
    }
    var primary: RecordingComponent? { components.first { $0.role == .screen } }
}

extension RecordingTake: TimelineDurationChangeable, TimelineCuttable, LibPreviewableProtocol {
    var clipSource: ClipSource { .init(id: "screenRecording:\(id)", kind: .video, displayName: name) }
    var mediaURL: URL? { primary.map { ProjectStorage.for(model: self).absoluteURL(for: $0.filePath) } }
    var storedDuration: Double? { duration }
    var naturalSize: CGSize? { primary.map { CGSize(width: $0.width, height: $0.height) } }
}
