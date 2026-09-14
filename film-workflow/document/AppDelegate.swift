import AppKit

/// Finder integration and shutdown. Everything else stays in SwiftUI.
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await RemotionFootageUITestFixture.openIfRequested() }
        TimelineTrackUITestFixture.openIfRequested()
        NarrativeCaptionUITestFixture.openIfRequested()
        StillPreviewUITestFixture.openIfRequested()
    }
    #endif

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            ProjectDocumentController.shared.requestOpen(url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ProjectDocumentController.shared.saveAll()
        #if os(macOS)
        Task { @MainActor in
            RemotionPreviewSessions.shared.stopAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
        #else
        return .terminateNow
        #endif
    }
}
