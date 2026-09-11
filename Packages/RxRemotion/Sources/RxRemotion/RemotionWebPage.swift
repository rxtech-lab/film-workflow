import AppKit
import Observation
import WebKit

@MainActor
final class ScriptRelay: NSObject, WKScriptMessageHandler {
    weak var page: RemotionWebPage?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }; page?.receive(message.body)
    }
}

@MainActor
final class RemotionWebPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let project: RemotionPreparedProject
    private var window: NSWindow?
    private var ready = false
    private var error: String?
    private var disposed = false
    private let mode: String
    private let captureSettings: RemotionRenderSettings
    private(set) var compositions: [RemotionComposition] = []
    var onEvent: ((RemotionPlaybackEvent) -> Void)?

    init(project: RemotionPreparedProject, mode: String, compositionID: String,
         inputProps: [String: RemotionJSON], settings: RemotionRenderSettings) async throws {
        guard (1...8192).contains(settings.width ?? 1920), (1...8192).contains(settings.height ?? 1080),
              (settings.fps ?? 30).isFinite, (settings.fps ?? 30) > 0, (settings.fps ?? 30) <= 240,
              (settings.captureScale ?? 1).isFinite, (settings.captureScale ?? 1) > 0, (settings.captureScale ?? 1) <= 1,
              project.configuration.frameTimeout.isFinite, project.configuration.frameTimeout > 0 else {
            throw RemotionError.rendering("Invalid render size, capture scale, frame rate, or resource timeout")
        }
        self.project = project; self.mode = mode; self.captureSettings = settings
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.websiteDataStore = .nonPersistent()
        let relay = ScriptRelay()
        configuration.userContentController.add(relay, name: "rxRemotion")
        let frame = NSRect(x: 0, y: 0, width: settings.width ?? 1920, height: settings.height ?? 1080)
        webView = WKWebView(frame: frame, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        // macOS WebKit's background drawing flag is required for transparent live layers.
        // Export uses the public snapshot API with two-background alpha reconstruction.
        if mode == "preview" { webView.setValue(false, forKey: "drawsBackground") }
        super.init()
        relay.page = self; webView.navigationDelegate = self
        if mode != "preview" {
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear; window.isOpaque = false
            window.contentView = webView
            self.window = window
        }
        webView.load(URLRequest(url: try project.pageURL(mode: mode, compositionID: compositionID, inputProps: inputProps, settings: settings)))
        do {
            let deadline = Date().addingTimeInterval(max(60, project.configuration.frameTimeout))
            while !ready {
                try Task.checkCancellation()
                if let error { throw mode == "compile" ? RemotionError.compilation(error) : RemotionError.rendering(error) }
                guard Date() < deadline else { throw RemotionError.rendering("Timed out starting the \(mode) WebView") }
                try await Task.sleep(for: .milliseconds(20))
            }
            if mode == "render", let c = compositions.first {
                webView.setFrameSize(NSSize(width: c.width, height: c.height))
                window?.setContentSize(NSSize(width: c.width, height: c.height))
            }
        } catch { dispose(); throw error }
    }
    func receive(_ body: Any) {
        guard !disposed, let message = body as? [String: Any], let type = message["type"] as? String else { return }
        func decode<T: Decodable>(_ object: Any, _: T.Type) -> T? {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        switch type {
        case "viewport":
            guard mode == "render", let c = decode(message, RemotionComposition.self),
                  (1...8192).contains(c.width), (1...8192).contains(c.height) else { return }
            webView.setFrameSize(NSSize(width: c.width, height: c.height))
            window?.setContentSize(NSSize(width: c.width, height: c.height))
        case "compiled": ready = true
        case "discovered": compositions = decode(message["compositions"] ?? [], [RemotionComposition].self) ?? []; ready = true
        case "ready":
            guard let c = decode(message, RemotionComposition.self) else { error = "Invalid composition metadata"; return }
            compositions = [c]; ready = true; onEvent?(.ready(c))
        case "frame": onEvent?(.frame(message["frame"] as? Int ?? 0))
        case "building": onEvent?(.building)
        case "buffering": onEvent?(.buffering(message["value"] as? Bool ?? false))
        case "ended": onEvent?(.ended)
        case "limitation": onEvent?(.limitation(message["message"] as? String ?? "Playback limitation"))
        case "error": error = message["message"] as? String ?? "JavaScript error"; onEvent?(.error(error!))
        default: break
        }
    }
    func advance(to frame: Int) async throws -> [RemotionAudioSample] {
        guard !disposed else { throw RemotionError.disposed }
        try Task.checkCancellation()
        let result: Any?
        do {
            result = try await withTaskCancellationHandler {
                try await webView.callAsyncJavaScript("return await window.rxRenderFrame(frame)", arguments: ["frame": frame], in: nil, contentWorld: .page)
            } onCancel: { Task { @MainActor in self.dispose() } }
        } catch {
            try Task.checkCancellation()
            throw RemotionError.rendering((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
        }
        try Task.checkCancellation()
        guard let object = result as? [String: Any], object["frame"] as? Int == frame else {
            throw RemotionError.rendering("The WebView returned a stale frame")
        }
        let data = try JSONSerialization.data(withJSONObject: object["assets"] ?? [])
        return try JSONDecoder().decode([RemotionAudioSample].self, from: data)
    }
    func capture(preserveAlpha: Bool = true) async throws -> CGImage {
        guard !disposed, let c = compositions.first else { throw RemotionError.disposed }
        try Task.checkCancellation()
        // WKSnapshotConfiguration uses points and WKWebView paints an opaque backing.
        // Two known backgrounds recover premultiplied alpha without private WebKit APIs.
        let script = "window.rxOriginalBackground ??= document.body.style.backgroundColor; document.body.style.backgroundColor=color;"
        _ = try await webView.callAsyncJavaScript(script, arguments: ["color": "black"], in: nil, contentWorld: .page)
        do {
            let black = try await snapshotImage(c)
            var white: CGImage?
            if preserveAlpha {
                _ = try await webView.callAsyncJavaScript(script, arguments: ["color": "white"], in: nil, contentWorld: .page)
                white = try await snapshotImage(c)
            }
            _ = try await webView.evaluateJavaScript("document.body.style.backgroundColor=window.rxOriginalBackground||''")
            let captured = captureSettings.capturedComposition(c)
            return try await CapturePixels.image(black: black, white: white, width: captured.width, height: captured.height)
        } catch {
            _ = try? await webView.evaluateJavaScript("document.body.style.backgroundColor=window.rxOriginalBackground||''")
            throw error
        }
    }
    private func snapshotImage(_ c: RemotionComposition) async throws -> CGImage {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: c.width, height: c.height)
        config.snapshotWidth = NSNumber(value: captureSettings.capturedComposition(c).width)
        config.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: config)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RemotionError.rendering("WebKit did not return a frame image")
        }
        return cg
    }
    func command(_ command: [String: Any]) async throws {
        guard !disposed else { throw RemotionError.disposed }
        _ = try await webView.callAsyncJavaScript("window.rxPendingCommand=command;window.rxPreviewCommand?.(command)", arguments: ["command": command], in: nil, contentWorld: .page)
    }
    func dispose() {
        guard !disposed else { return }; disposed = true
        webView.stopLoading(); webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rxRemotion")
        webView.loadHTMLString("", baseURL: nil); window?.close(); window = nil; onEvent = nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        ready = false; error = nil; onEvent?(.building)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        error = "The WebKit content process stopped. Reload the preview."; onEvent?(.error(error!))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription; onEvent?(.error(error.localizedDescription))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let base = project.baseURL else { decisionHandler(.cancel); return }
        decisionHandler(url.host == base.host && url.port == base.port && url.path.hasPrefix(base.path + "/") ? .allow : .cancel)
    }
}

@MainActor @Observable
public final class RemotionPreviewSession {
    public private(set) var composition: RemotionComposition?
    public private(set) var isBuffering = false
    public private(set) var lastError: String?
    public var onEvent: ((RemotionPlaybackEvent) -> Void)?
    @ObservationIgnored private let page: RemotionWebPage
    @ObservationIgnored private var serial = 0
    public private(set) var frame = 0
    public private(set) var playing = false
    private var rate = 1.0
    private var volume = 1.0
    private var muted = false
    public var webView: WKWebView { page.webView }
    init(project: RemotionPreparedProject, compositionID: String, inputProps: [String: RemotionJSON], settings: RemotionRenderSettings) async throws {
        page = try await RemotionWebPage(project: project, mode: "preview", compositionID: compositionID, inputProps: inputProps, settings: settings)
        composition = page.compositions.first
        page.onEvent = { [weak self] event in
            switch event {
            case .ready(let c):
                self?.composition = c; self?.isBuffering = false; self?.lastError = nil
                Task { @MainActor [weak self] in try? await self?.send() }
            case .building: self?.isBuffering = true
            case .frame(let f): self?.frame = f
            case .buffering(let value): self?.isBuffering = value
            case .error(let message), .limitation(let message): self?.lastError = message
            case .ended: self?.playing = false
            }
            self?.onEvent?(event)
        }
    }
    public func seek(to frame: Int) async throws { self.frame = min(max(0, frame), (composition?.durationInFrames ?? 1) - 1); try await send() }
    public func play() async throws { playing = true; try await send() }
    public func pause() async throws { playing = false; try await send() }
    public func setPlaybackRate(_ rate: Double) async throws { guard rate.isFinite, rate > 0, rate <= 10 else { throw RemotionError.unsupported("Preview playback rate must be greater than zero and at most 10") }; self.rate = rate; try await send() }
    public func setVolume(_ volume: Double) async throws { guard volume.isFinite, (0...1).contains(volume) else { throw RemotionError.unsupported("Preview volume must be between zero and one") }; self.volume = volume; try await send() }
    public func setMuted(_ muted: Bool) async throws { self.muted = muted; try await send() }
    private func send() async throws {
        serial += 1
        try await page.command(["serial": serial,"frame": frame,"playing": playing,"rate": rate,"volume": volume,"muted": muted])
    }
    public func dispose() { page.dispose() }
}
