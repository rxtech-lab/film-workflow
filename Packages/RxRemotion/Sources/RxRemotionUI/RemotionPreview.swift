import AppKit
import RxRemotion
import SwiftUI

/// Each mounted session owns its playhead. The caller controls session disposal.
public struct RemotionPreview: NSViewRepresentable {
    public let session: RemotionPreviewSession
    public init(session: RemotionPreviewSession) { self.session = session }
    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        mount(in: container)
        return container
    }
    public func updateNSView(_ view: NSView, context: Context) { mount(in: view) }
    private func mount(in container: NSView) {
        let webView = session.webView
        guard container.subviews.first !== webView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
