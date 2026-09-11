import SwiftData
import SwiftUI
import TipKit

@main
struct film_workflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var controller = ProjectDocumentController.shared

    // Held for the lifetime of the app: creating it starts Sparkle's scheduled
    // update check, so the app also updates itself without the menu command.
    private let updateService = UpdateService.shared

    init() {
        FileStorage.ensureDirectories()
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
            Tips.hideAllTipsForTesting()
        }
        // Audio chunks and multipart bodies staged during transcription can be
        // hundreds of megabytes; a crash mid-run would otherwise leak them.
        FileStorage.clearTemp()

    }

    /// Runs once per window that can start the app. Skipped under XCTest: the
    /// keychain read behind `checkExistingAuth` can raise a system prompt that
    /// would stall the test runner before it connects.
    private static var didBootstrap = false
    private static func bootstrapServices() async {
        guard !didBootstrap, NSClassFromString("XCTestCase") == nil else { return }
        didBootstrap = true
        MCPServer.shared.bootstrap()
        // `-skipStartupAuth` lets a debug launch skip the keychain read, whose
        // access prompt would otherwise block an unattended run.
        if !ProcessInfo.processInfo.arguments.contains("-skipStartupAuth") {
            await AuthManager.shared.checkExistingAuth()
            if let error = CreditBalanceStore.shared.error {
                let alert = NSAlert()
                alert.messageText = String(localized: "Couldn’t Connect to Server")
                alert.informativeText = error
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(localized: "OK"))
                alert.runModal()
            }
        }
    }

    var body: some Scene {
        // One editor window per film. The URL is the scene value so state
        // restoration reopens the same packages.
        WindowGroup(id: EditorWindowID.value, for: URL.self) { $url in
            EditorWindowRoot(documentURL: url)
                .signInSheetPresenter()
                .task { await Self.bootstrapServices() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Film…") {
                    Task {
                        guard let url = await controller.presentNewPanel() else { return }
                        do {
                            try controller.createDocument(at: url)
                            openWindow(id: EditorWindowID.value, value: url)
                        } catch {
                            NSAlert(error: error).runModal()
                        }
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open…") {
                    Task {
                        guard let url = await controller.presentOpenPanel() else { return }
                        openWindow(id: EditorWindowID.value, value: url)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    ForEach(controller.recentDocumentURLs, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            openWindow(id: EditorWindowID.value, value: url)
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        NSDocumentController.shared.clearRecentDocuments(nil)
                    }
                }
                Divider()
                Button("Welcome to RxFilmStudio") {
                    openWindow(id: WelcomeWindowID.value)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updateService.checkForUpdates()
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Agent") {
                    openWindow(id: AgentWindowID.value)
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
            MediaImportCommands()
            AccountCommands()
        }

        Window("Welcome to RxFilmStudio", id: WelcomeWindowID.value) {
            WelcomeWindowView()
                .signInSheetPresenter()
                .task { await Self.bootstrapServices() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)

        // One agent window for the whole app — a `Window` rather than a
        // `WindowGroup` because there is exactly one of it, so reopening raises
        // the existing window instead of minting another. Threads live in the
        // app-level store; the film they work on is looked up per turn.
        Window("Agent", id: AgentWindowID.value) {
            AgentWindowView()
                .environment(AgentController.shared)
                .signInSheetPresenter()
                // Nothing inside the agent window paints a ground of its own,
                // so the window supplies one: a material rather than a solid
                // fill, which is what makes the panel read as glass over
                // whatever is behind it instead of a grey slab.
                .containerBackground(.ultraThinMaterial, for: .window)
        }
        .modelContainer(AppModelContainer.shared)
        .defaultSize(width: 760, height: 720)

        Settings {
            SettingsView()
                .signInSheetPresenter()
        }
    }
}
