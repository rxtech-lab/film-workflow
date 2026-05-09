#if os(macOS)
import SwiftUI
import WebKit

struct RemotionPreviewWebView: NSViewRepresentable {
    let url: URL?
    let reloadToken: Int

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let userContent = WKUserContentController()
        let script = WKUserScript(
            source: Self.hideRenderButtonScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        userContent.addUserScript(script)
        config.userContentController = userContent

        let view = NoContextMenuWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = false
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    final class NoContextMenuWebView: WKWebView {
        override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
            menu.removeAllItems()
        }
    }

    private static let hideRenderButtonScript = """
    (function () {
      if (window.__rxStudioHider) return;
      window.__rxStudioHider = true;

      // Topbar's menu-initiator button sits in a wrapper div with no aria-label.
      // The playback bar also uses __remotion-studio-menu-initiator (for the
      // "Preview Size" and "Playback Rate" dropdowns), but those wrappers carry
      // aria-label, so :not([aria-label]) keeps them visible.
      var styleEl = document.createElement('style');
      styleEl.textContent =
        'div.css-reset:has(> div:not([aria-label]) > button.__remotion-studio-menu-initiator) { display: none !important; }' +
        'html, body, * { -webkit-user-select: none !important; user-select: none !important; -webkit-touch-callout: none !important; }' +
        'input, textarea, [contenteditable="true"], [contenteditable=""] { -webkit-user-select: text !important; user-select: text !important; }';
      (document.head || document.documentElement).appendChild(styleEl);

      var hideUpdateModal = function () {
        var dialogs = document.querySelectorAll('[role="dialog"], [aria-modal="true"]');
        for (var i = 0; i < dialogs.length; i++) {
          var d = dialogs[i];
          if (d.dataset && d.dataset.rxHidden === '1') continue;
          var text = (d.textContent || '').trim();
          if (/update available|a new update for remotion is available/i.test(text)) {
            d.style.display = 'none';
            if (d.dataset) d.dataset.rxHidden = '1';
          }
        }
      };

      hideUpdateModal();

      var pending = false;
      var observer = new MutationObserver(function () {
        if (pending) return;
        pending = true;
        requestAnimationFrame(function () {
          pending = false;
          hideUpdateModal();
        });
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });
    })();
    """

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
