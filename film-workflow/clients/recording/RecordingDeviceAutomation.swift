import Foundation

/// Optional Appium/XCUITest adapter. Device trust and signing remain in Xcode.
@MainActor final class RecordingDeviceAutomation {
    static let shared = RecordingDeviceAutomation()
    private var sessionID: String?
    private var configuration: RecordingSettings?
    var setupInstructions: String { "Install and start Appium with the XCUITest driver. In Xcode, trust the wired device and configure WebDriverAgent signing. Enable Developer Mode and UI Automation on the device. Enter its UDID and app bundle ID below." }
    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, settings: RecordingSettings) async throws -> [String: Any] {
        guard let base = URL(string: settings.deviceAutomationURL), ["http", "https"].contains(base.scheme ?? ""), let url = URL(string: settings.deviceAutomationURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { throw RecordingError.message("Enter a valid Appium server URL.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 90
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let value = object["value"] as? [String: Any]
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), value?["error"] == nil else { throw RecordingError.message(value?["message"] as? String ?? "Device automation failed. Check Appium and WebDriverAgent setup.") }
        return object
    }
    func connect(settings: RecordingSettings) async throws {
        if sessionID != nil, configuration?.deviceUDID == settings.deviceUDID, configuration?.deviceAutomationURL == settings.deviceAutomationURL, configuration?.deviceAppBundleID == settings.deviceAppBundleID { return }
        guard !settings.deviceUDID.isEmpty else { throw RecordingError.message("Enter the device UDID in recording settings.") }
        let result = try await request("/session", method: "POST", body: ["capabilities": ["alwaysMatch": ["platformName": "iOS", "appium:automationName": "XCUITest", "appium:udid": settings.deviceUDID, "appium:bundleId": settings.deviceAppBundleID, "appium:noReset": true]]], settings: settings)
        guard let id = (result["value"] as? [String: Any])?["sessionId"] as? String ?? result["sessionId"] as? String else { throw RecordingError.message("Appium did not return a session ID.") }; sessionID = id; configuration = settings
    }
    func screenshot(settings: RecordingSettings) async throws -> Data {
        try await connect(settings: settings)
        let result = try await request("/session/\(sessionID!)/screenshot", settings: settings)
        guard let raw = result["value"] as? String, let data = Data(base64Encoded: raw) else { throw RecordingError.message("The device did not return a screenshot.") }; return data
    }
    func perform(_ action: RecordingAction, settings: RecordingSettings) async throws {
        try await connect(settings: settings); let path = "/session/\(sessionID!)"
        if action.kind == .deviceText {
            _ = try await request(path + "/execute/sync", method: "POST", body: ["script": "mobile: keys", "args": [["keys": [action.text]]]], settings: settings); return
        }
        let result = try await request(path + "/window/rect", settings: settings)
        guard let rect = result["value"] as? [String: Any], let width = rect["width"] as? Double, let height = rect["height"] as? Double else { throw RecordingError.message("Cannot determine device screen size.") }
        var steps: [[String: Any]] = [["type": "pointerMove", "duration": 0, "x": Int(action.x * width), "y": Int(action.y * height)], ["type": "pointerDown", "button": 0]]
        if action.kind == .deviceSwipe { steps.append(["type": "pointerMove", "duration": Int(max(0.1, action.duration) * 1000), "x": Int(action.endX * width), "y": Int(action.endY * height)]) }
        steps.append(["type": "pointerUp", "button": 0])
        _ = try await request(path + "/actions", method: "POST", body: ["actions": [["type": "pointer", "id": "finger", "parameters": ["pointerType": "touch"], "actions": steps]]], settings: settings)
    }
}
