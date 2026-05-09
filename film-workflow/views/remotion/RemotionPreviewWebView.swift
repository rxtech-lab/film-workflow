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

      // Hide a small set of Studio chrome elements via precise selectors.
      // Each rule targets a single, specific element — nothing structural.
      var styleEl = document.createElement('style');
      styleEl.textContent = [
        // Menu dropdown initiator on the topbar.
        'button.__remotion-studio-menu-initiator { display: none !important; }',
        // Sidebar toggles — Studio puts the title on a child <div>.
        'button:has(> div[title*="Toggle Left Sidebar"]) { display: none !important; }',
        'button:has(> div[title*="Toggle Right Sidebar"]) { display: none !important; }'
      ].join('\\n');
      (document.head || document.documentElement).appendChild(styleEl);

      var matchesRender = function (el) {
        if (!el) return false;
        var label = (el.getAttribute && el.getAttribute('aria-label')) || '';
        if (/render/i.test(label)) return true;
        var title = (el.getAttribute && el.getAttribute('title')) || '';
        if (/render/i.test(title)) return true;
        var text = (el.textContent || '').trim();
        return /^render$/i.test(text);
      };

      var matchesUpdate = function (el) {
        if (!el) return false;
        var label = (el.getAttribute && el.getAttribute('aria-label')) || '';
        if (/upgrade|update available|new update/i.test(label)) return true;
        var title = (el.getAttribute && el.getAttribute('title')) || '';
        if (/upgrade|update available|new update/i.test(title)) return true;
        return false;
      };

      var matchesPanelToggle = function (el) {
        if (!el) return false;
        var label = (el.getAttribute && el.getAttribute('aria-label')) || '';
        if (/(show|hide|toggle|expand|collapse).*(panel|sidebar|sidebars)/i.test(label)) return true;
        if (/(left|right).*(panel|sidebar)/i.test(label)) return true;
        var title = (el.getAttribute && el.getAttribute('title')) || '';
        if (/(show|hide|toggle|expand|collapse).*(panel|sidebar|sidebars)/i.test(title)) return true;
        if (/(left|right).*(panel|sidebar)/i.test(title)) return true;
        return false;
      };

      var hideButtons = function () {
        var nodes = document.querySelectorAll('button, a[role="button"]');
        for (var i = 0; i < nodes.length; i++) {
          var n = nodes[i];
          if (n.dataset && n.dataset.rxHidden === '1') continue;
          if (matchesRender(n) || matchesUpdate(n) || matchesPanelToggle(n)) {
            n.style.display = 'none';
            if (n.dataset) n.dataset.rxHidden = '1';
          }
        }
      };

      var hideUpdateModal = function () {
        // Only target real modal containers — never search arbitrary text nodes,
        // since that can match strings inside the user's composition (or studio
        // chrome) and end up hiding wide ancestors.
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

      var run = function () {
        hideButtons();
        hideUpdateModal();
      };

      run();

      var pending = false;
      var observer = new MutationObserver(function () {
        if (pending) return;
        pending = true;
        requestAnimationFrame(function () {
          pending = false;
          run();
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
