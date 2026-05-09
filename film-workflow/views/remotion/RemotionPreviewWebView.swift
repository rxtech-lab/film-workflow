#if os(macOS)
import SwiftUI
import WebKit

struct RemotionPreviewWebView: NSViewRepresentable {
    let url: URL?
    let reloadToken: Int

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = false
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let url = url else {
            nsView.loadHTMLString(emptyHTML, baseURL: nil)
            return
        }
        let needsLoad = nsView.url == nil || nsView.url?.absoluteString != url.absoluteString
        if needsLoad {
            nsView.load(URLRequest(url: url))
            return
        }
        // Token changed since last update — explicit reload to surface latest source.
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            nsView.reload()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(reloadToken: reloadToken)
    }

    final class Coordinator {
        var lastReloadToken: Int
        init(reloadToken: Int) { self.lastReloadToken = reloadToken }
    }

    private let emptyHTML = """
    <html><body style="background:#1e1e1e;color:#888;font-family:-apple-system;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;">
    <div>No project selected</div></body></html>
    """
}
#endif
