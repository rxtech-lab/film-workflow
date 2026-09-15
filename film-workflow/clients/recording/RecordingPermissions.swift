import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI

enum RecordingPermission: String, CaseIterable, Identifiable {
    case screen, input, camera, microphone, accessibility
    var id: String { rawValue }
    var title: String {
        switch self {
        case .screen: "Screen Recording"
        case .input: "Input Monitoring"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        }
    }
    var explanation: String {
        switch self {
        case .screen: "Capture the display, windows, or area you choose."
        case .input: "Save mouse movement and keyboard shortcuts as editable recording tracks."
        case .camera: "Include your selected camera or connected device."
        case .microphone: "Record sound from your selected microphone or connected device."
        case .accessibility: "Replay the mouse and keyboard actions you saved."
        }
    }
    var settingsPane: String {
        switch self {
        case .screen: "Privacy_ScreenCapture"
        case .input: "Privacy_ListenEvent"
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        }
    }
}

@MainActor @Observable final class RecordingPermissions {
    static let shared = RecordingPermissions()
    private(set) var granted: Set<RecordingPermission> = []
    private(set) var requesting: RecordingPermission?
    private var observer: NSObjectProtocol?
    private let probe: (() -> Set<RecordingPermission>)?
    init(probe: (() -> Set<RecordingPermission>)? = nil) {
        self.probe = probe
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    var baseGranted: Bool { granted.isSuperset(of: [.screen, .input]) }
    static func required(for settings: RecordingSettings?, replay: Bool = false) -> [RecordingPermission] {
        var result: [RecordingPermission] = [.screen, .input]
        if let settings {
            if !settings.cameraIDs.isEmpty || settings.sourceKind == .device { result.append(.camera) }
            if !settings.microphoneIDs.isEmpty || settings.sourceKind == .device { result.append(.microphone) }
        }
        if replay { result.append(.accessibility) }
        return result
    }
    func allows(_ settings: RecordingSettings, replay: Bool = false) -> Bool {
        granted.isSuperset(of: Self.required(for: settings, replay: replay))
    }
    func refresh() {
        if let probe { granted = probe(); return }
        var value = Set<RecordingPermission>()
        if CGPreflightScreenCaptureAccess() { value.insert(.screen) }
        if CGPreflightListenEventAccess() { value.insert(.input) }
        if AXIsProcessTrusted() { value.insert(.accessibility) }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { value.insert(.camera) }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { value.insert(.microphone) }
        granted = value
    }
    func request(_ permission: RecordingPermission) async {
        guard requesting == nil else { return }
        requesting = permission
        defer { requesting = nil; refresh() }
        switch permission {
        case .screen: _ = CGRequestScreenCaptureAccess()
        case .input: _ = CGRequestListenEventAccess()
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        case .camera: _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }
    func openSettings(_ permission: RecordingPermission) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsPane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct RecordingPermissionGuide: View {
    var settings: RecordingSettings?
    var replay = false
    var showsAllPermissions = false
    @State private var permissions: RecordingPermissions
    init(settings: RecordingSettings? = nil, replay: Bool = false, showsAllPermissions: Bool = false, permissions: RecordingPermissions? = nil) {
        self.settings = settings; self.replay = replay; self.showsAllPermissions = showsAllPermissions
        _permissions = State(initialValue: permissions ?? .shared)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(showsAllPermissions ? "Recording Permissions" : "Set Up Recording", systemImage: "lock.shield").font(.title2.bold())
            Text(showsAllPermissions ? "Review and grant access for all recording features." : "Complete these steps to use the recorder. Your selection will be kept while you update permissions.")
                .foregroundStyle(.secondary)
            ForEach(Array((showsAllPermissions ? RecordingPermission.allCases : RecordingPermissions.required(for: settings, replay: replay)).enumerated()), id: \.element.id) { index, permission in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: permissions.granted.contains(permission) ? "checkmark.circle.fill" : "\(index + 1).circle")
                        .font(.title2).foregroundStyle(permissions.granted.contains(permission) ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(permission.title).font(.headline)
                        Text(permission.explanation).font(.callout).foregroundStyle(.secondary)
                        if !permissions.granted.contains(permission) {
                            Text("In System Settings → Privacy & Security → \(permission.title), enable RxFilmStudio.").font(.caption)
                            ViewThatFits(in: .horizontal) {
                                HStack { permissionButtons(permission) }
                                VStack(alignment: .leading) { permissionButtons(permission) }
                            }
                        } else { Text("Access granted").font(.caption).foregroundStyle(.green) }
                    }
                }
            }
            Text("If macOS asks you to quit and reopen RxFilmStudio, save your film and reopen the app. Access may not take effect until then.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check Again", systemImage: "arrow.clockwise") { permissions.refresh() }
        }.padding(20).task { permissions.refresh() }
    }
    @ViewBuilder private func permissionButtons(_ permission: RecordingPermission) -> some View {
        Button("Allow Access") { Task { await permissions.request(permission) } }
            .disabled(permissions.requesting != nil)
            .accessibilityLabel("Allow \(permission.title)")
            .accessibilityIdentifier("recording.permissions.\(permission.rawValue).allow")
        Button("Open Settings") { permissions.openSettings(permission) }
            .accessibilityLabel("Open \(permission.title) Settings")
            .accessibilityIdentifier("recording.permissions.\(permission.rawValue).settings")
    }
}
