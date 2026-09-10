import AppKit

/// Finder integration and shutdown. Everything else stays in SwiftUI.
final class AppDelegate: NSObject, NSApplicationDelegate {
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
            await RemotionRuntime.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
        #else
        return .terminateNow
        #endif
    }
}
