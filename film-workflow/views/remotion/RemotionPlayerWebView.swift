import SwiftUI
import VideoEditorCore
import WebKit

/// The web page only renders a composition. Native controls own its transport.
struct RemotionPlayerWebView: NSViewRepresentable {
    let playback: LivePreviewPlayback

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(context.coordinator, name: "rxRemotion")
        let view = RemotionPreviewWebView.NoContextMenuWebView(frame: .zero, configuration: config)
        view.underPageBackgroundColor = .clear
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        view.load(URLRequest(url: playback.descriptor.url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.send(playback.command)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        coordinator.playback.ready = false
        view.configuration.userContentController.removeScriptMessageHandler(forName: "rxRemotion")
        view.navigationDelegate = nil
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let playback: LivePreviewPlayback
        weak var webView: WKWebView?
        var active = true
        private var lastSerial = -1

        init(playback: LivePreviewPlayback) { self.playback = playback }

        func send(_ command: LivePreviewCommand) {
            guard active, command.serial != lastSerial, let webView,
                  let data = try? JSONEncoder().encode(command),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return }
            lastSerial = command.serial
            Task { @MainActor [weak self, weak webView] in
                guard let self, self.active, let webView else { return }
                _ = try? await webView.callAsyncJavaScript("window.rxPendingCommand = command; window.rxPreviewCommand?.(command);",
                                                         arguments: ["command": object], in: nil, contentWorld: .page)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "ready" {
                if let fps = body["fps"] as? Int, fps > 0 { playback.descriptor.fps = fps }
                if let frames = body["frames"] as? Int, frames > 0 { playback.descriptor.frames = frames }
                lastSerial = -1
            }
            playback.received(type: type, message: body["message"] as? String, buffering: body["value"] as? Bool ?? false)
            if type == "ready" { send(playback.command) }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            lastSerial = -1
            playback.received(type: "building")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { send(playback.command) }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard active, (error as NSError).code != NSURLErrorCancelled else { return }
            playback.received(type: "error", message: error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard active else { return }
            playback.received(type: "error", message: "The preview stopped. Retry to reload it.")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            let expected = playback.descriptor.url
            decisionHandler(url.host == expected.host && url.port == expected.port && url.path.hasPrefix(expected.path) ? .allow : .cancel)
        }
    }
}
