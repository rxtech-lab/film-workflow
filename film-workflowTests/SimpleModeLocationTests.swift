import AppKit
import FilmTemplateKit
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import film_workflow

@Suite("Wizard location picker", .serialized) @MainActor
struct SimpleModeLocationTests {
    @Test("The native picker opens and cancellation preserves the brief")
    func nativePicker() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WizardPicker-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SimpleModeSession(template: FilmTemplateCatalog.companyIntro)
        session.reviewLocation(for: IntakeSubmission(formValues: ["projectName": "My film", "website": "example.com"]))
        var continued = false
        let host = NSHostingView(rootView: SimpleModeLocationPage(session: session, onContinue: { continued = true }, onCancel: {}))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1000, height: 780),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { NSApp.windows.compactMap { $0 as? NSSavePanel }.forEach { $0.cancel(nil) }; window.close() }
        try await Task.sleep(for: .milliseconds(400))
        #expect(!continued)
        try press("wizard.location.choose", in: host)
        let first = try await picker()
        #expect(first.allowedContentTypes.contains(.rxFilmStudioProject))
        #expect(first.nameFieldStringValue == "My film")
        first.cancel(nil)
        try await Task.sleep(for: .milliseconds(300))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        #expect(session.destinationURL == nil)
        #expect(session.intake?.projectName == "My film")
        #expect(session.step == .chooseLocation)

        session.chooseDestination(root.appendingPathComponent("Picked Film.rxfilmstudio"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.destinationURL?.lastPathComponent == "Picked Film.rxfilmstudio")
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/film-wizard-location.png"))
    }

    private func press(_ identifier: String, in host: NSView) throws {
        let control = try #require(hostedAccessibilityDescendants(host).first { $0.accessibilityIdentifier() == identifier })
        #expect(control.accessibilityPerformPress())
    }

    private func picker() async throws -> NSSavePanel {
        for _ in 0..<100 {
            if let panel = NSApp.windows.compactMap({ $0 as? NSSavePanel }).first(where: \.isVisible) { return panel }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "WizardPickerTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "The native save picker did not open"])
    }
}
