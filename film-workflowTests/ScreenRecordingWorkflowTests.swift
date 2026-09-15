import AppKit
import AVFoundation
import CoreGraphics
import RxPet
import ScreenCaptureKit
import SwiftData
import Testing
import VideoEditorCore
@testable import film_workflow

@MainActor @Suite("Screen recording workflow", .serialized) struct ScreenRecordingWorkflowTests {
    private func package() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("RecordingTests-\(UUID()).rxfilmstudio") }
    @Test func persistenceAndIndependentInsertions() async throws {
        let url = package(); defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let project = ScreenRecordingProject(name: "Product Demo"); document.container.mainContext.insert(project)
        let take = RecordingTake(name: "Take 1"); take.duration = 4; take.project = project
        var presentation = RecordingClipPresentation(); presentation.pointer = [.init(time: 1, x: 0.5, y: 0.5, clicked: true)]
        take.components = [.init(role: .screen, name: "Safari", filePath: "screen.mov", duration: 4, width: 1280, height: 720, presentation: presentation), .init(role: .microphone, name: "Narrator", filePath: "mic.mov", duration: 4), .init(role: .shortcuts, name: "Shortcuts", filePath: "", duration: 4, cues: [.init(start: 1, end: 2, text: "⌘K")])]
        document.container.mainContext.insert(take)
        let sequence = SequenceProject(name: "Cut"); document.container.mainContext.insert(sequence)
        let undo = UndoManager(); undo.groupsByEvent = false; undo.beginUndoGrouping()
        let first = try RecordingTimelineService.insert(take: take, into: sequence, at: 0, undoManager: undo)
        undo.endUndoGrouping()
        #expect(first.count == 3); #expect(Set(sequence.timeline.allClips.compactMap(\.linkGroupID)).count == 1)
        undo.undo(); #expect(sequence.timeline.allClips.isEmpty)
        undo.redo(); #expect(sequence.timeline.allClips.count == 3)
        let second = try RecordingTimelineService.insert(take: take, into: sequence, at: 5)
        #expect(Set(sequence.timeline.allClips.compactMap(\.recordingInstanceID)).count == 2)
        #expect(sequence.timeline.clip(id: first[0])?.recordingInstanceID != sequence.timeline.clip(id: second[0])?.recordingInstanceID)
        #expect(sequence.timeline.allClips.first { $0.source.kind == .captions }?.recordingShortcuts?.first?.text == "⌘K")
        try document.container.mainContext.save()
        let projectID = project.id, takeID = take.id, sequenceID = sequence.id
        await document.close()
        let reopened = try ProjectDocument.open(url)
        let saved = try #require(reopened.container.mainContext.fetch(FetchDescriptor<ScreenRecordingProject>(predicate: #Predicate { $0.id == projectID })).first)
        #expect(saved.takes.map(\.id) == [takeID])
        let cut = try #require(reopened.container.mainContext.fetch(FetchDescriptor<SequenceProject>(predicate: #Predicate { $0.id == sequenceID })).first)
        #expect(Set(cut.timeline.allClips.compactMap(\.linkGroupID)).count == 2)
        await reopened.close()
    }
    @Test func actionsValidateBeforeMutationAndKeepRevisions() async throws {
        let url = package(); defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url), project = ScreenRecordingProject(name: "Actions")
        document.container.mainContext.insert(project)
        var action = RecordingAction(kind: .click); action.bundleID = "com.apple.Safari"; action.windowID = 42
        try RecordingActionDocumentService.replace([action], project: project, document: document, undoManager: nil)
        var invalid = action; invalid.time = -1
        #expect(throws: (any Error).self) { try RecordingActionDocumentService.replace([invalid], project: project, document: document, undoManager: nil) }
        #expect(project.actions == [action])
        #expect(throws: (any Error).self) { try RecordingActionDocumentService.replace([action, action], project: project, document: document, undoManager: nil) }
        var secure = RecordingAction(kind: .secureInput); secure.text = "should never be saved"
        #expect(throws: (any Error).self) { try RecordingActionDocumentService.replace([secure], project: project, document: document, undoManager: nil) }
        let revisions = url.appendingPathComponent("Media/ScreenRecordings/\(project.id)/Actions")
        #expect(try FileManager.default.contentsOfDirectory(atPath: revisions.path).count == 1)
        await document.close()
    }
    @Test func screenClockPausesAndMapsSamples() async throws {
        let clock = RecordingClock(); clock.reset()
        try await Task.sleep(for: .milliseconds(30))
        let before = clock.elapsed; clock.pause(); let paused = clock.elapsed
        try await Task.sleep(for: .milliseconds(35))
        #expect(abs(clock.elapsed - paused) < 0.001)
        #expect(clock.time(for: CMClockGetTime(CMClockGetHostTimeClock())) == nil)
        clock.resume(); try await Task.sleep(for: .milliseconds(25))
        #expect(clock.elapsed > before)
        #expect(abs(try #require(clock.time(for: CMClockGetTime(CMClockGetHostTimeClock()))) - clock.elapsed) < 0.01)
    }
    @Test func screenshotEnvelopeAndToolParity() {
        let sample = WindowScreenshot(windowID: 42, title: "Checkout", bundleID: "com.apple.Safari", png: Data([1, 2, 3]), width: 80, height: 60)
        let failed = WindowScreenshot(windowID: 43, title: "Gone", bundleID: "com.apple.Safari", png: nil, error: "Window closed")
        let result = MCPRecordingHandlers.screenshotResult([sample, failed])
        let content = result["content"] as? [[String: Any]]
        #expect(content?.filter { $0["type"] as? String == "image" }.count == 1)
        #expect(((result["structuredContent"] as? [String: Any])?["windows"] as? [[String: Any]])?.count == 2)
        let descriptors = MCPToolRegistry.allDescriptors().map(\.name)
        for name in ["recording_sources", "recording_focus", "recording_screenshot", "recording_start", "recording_control", "recording_actions_edit", "recording_insert_take", "recording_pet", "sequence_link_clips", "sequence_track_alias"] { #expect(descriptors.contains(name)) }
    }
}

@MainActor @Suite("Live recording captures", .serialized) struct LiveScreenRecordingTests {
    @Test(.enabled(if: CGPreflightScreenCaptureAccess(), "Requires Screen Recording permission for the test app"))
    func windowScreenshotsPersistWithoutOverlay() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiveWindow-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 420, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.backgroundColor = .green
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 320))
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor.green.cgColor; window.contentView = view
        window.orderFrontRegardless(); window.displayIfNeeded()
        let pet = PetOverlayPresenter()
        defer { if let id = pet.windowID { RecordingSources.shared.excludedWindowIDs.remove(id) }; pet.dismiss(); window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        pet.prepare(state: PetState(status: .replaying, message: "Window capture test"), target: window.frame, visibleFrame: window.frame)
        RecordingSources.shared.excludedWindowIDs.insert(try #require(pet.windowID))
        let baseline = try await RecordingScreenshotService.capture(windowID: CGWindowID(window.windowNumber))
        let baselineData = try #require(baseline.first?.png)
        let baselineBitmap = try #require(NSBitmapImageRep(data: baselineData))
        pet.reveal()
        let results = try await RecordingScreenshotService.capture(windowID: CGWindowID(window.windowNumber), saveTo: document)
        let shot = try #require(results.first), data = try #require(shot.png)
        #expect(shot.error == nil); #expect(shot.footageID != nil)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(center.greenComponent > center.redComponent + 0.2 && center.greenComponent > center.blueComponent + 0.2)
        for y in stride(from: bitmap.pixelsHigh / 5, to: bitmap.pixelsHigh * 9 / 10, by: 20) {
            for x in stride(from: bitmap.pixelsWide / 10, to: bitmap.pixelsWide * 9 / 10, by: 20) {
                let a = try #require(baselineBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let b = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                #expect(abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.03)
            }
        }
        let assets = try document.container.mainContext.fetch(FetchDescriptor<ImportedAsset>())
        #expect(assets.count == 1); #expect(assets.first?.captureMetadata != nil)
        let app = try #require(Bundle.main.bundleIdentifier)
        let appShots = try await RecordingScreenshotService.capture(bundleID: app)
        #expect(appShots.contains { $0.windowID == CGWindowID(window.windowNumber) && $0.png != nil })
        #expect(appShots.allSatisfy { $0.windowID != pet.windowID })
        var settings = RecordingSettings(); settings.sourceKind = .window; settings.sourceID = String(window.windowNumber)
        let filter = try RecordingSources.shared.filter(for: settings).0
        let configuration = SCStreamConfiguration(); configuration.width = 420; configuration.height = 320; configuration.showsCursor = false
        let clock = RecordingClock(); clock.reset()
        let movie = url.appendingPathComponent("static-window.mov")
        let writer = RecordingMediaWriter(url: movie, video: true, clock: clock)
        let stream = try RecordingScreenStream(filter: filter, configuration: configuration, writer: writer)
        try await stream.stream.startCapture()
        try await Task.sleep(for: .milliseconds(800)); clock.pause()
        let paused = clock.elapsed; try await Task.sleep(for: .milliseconds(200)); #expect(abs(clock.elapsed - paused) < 0.01)
        clock.resume(); try await Task.sleep(for: .milliseconds(400)); clock.pause()
        try await stream.stream.stopCapture()
        let recorded = try #require(try await writer.finish())
        let assetDuration = try await AVURLAsset(url: movie).load(.duration).seconds
        #expect(abs(recorded.start + recorded.duration - clock.elapsed) < 1.0 / 30)
        #expect(assetDuration > 0.9, "A static final picture must keep the full recording duration")
        await document.close()
    }
    // Xcode's hosted unit-test windows can be captured individually while remaining
    // absent from the visible desktop. Run this check in an interactive test host.
    @Test(.enabled(if: CGPreflightScreenCaptureAccess() && ProcessInfo.processInfo.environment["RX_RECORDING_LIVE_DISPLAY_TEST"] == "1", "Requires an interactive desktop test host and RX_RECORDING_LIVE_DISPLAY_TEST=1"))
    func petIsExcludedFromAreaAndWindowScreenshots() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiveCapture-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 420, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .green
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 320)); view.wantsLayer = true; view.layer?.backgroundColor = NSColor.green.cgColor
        window.contentView = view; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let pet = PetOverlayPresenter()
        defer { if let id = pet.windowID { RecordingSources.shared.excludedWindowIDs.remove(id) }; pet.dismiss(); window.orderOut(nil) }
        let screen = try #require(NSScreen.screens.first)
        pet.prepare(state: PetState(status: .replaying, message: "Capture exclusion test"), target: CGRect(x: window.frame.minX - 15, y: window.frame.minY, width: 1, height: window.frame.height), visibleFrame: screen.visibleFrame)
        let petID = try #require(pet.windowID)
        RecordingSources.shared.excludedWindowIDs.insert(petID)
        try await RecordingSources.shared.refresh()
        #expect(RecordingSources.shared.content?.windows.contains { $0.windowID == petID } == true)
        let display = try #require(RecordingSources.shared.content?.displays.first { $0.frame.contains(CGPoint(x: 200, y: screen.frame.maxY - 200)) })
        var settings = RecordingSettings(); settings.sourceKind = .area; settings.sourceID = String(display.displayID)
        settings.area = CGRect(x: window.frame.minX, y: screen.frame.maxY - window.frame.minY - 320, width: 420, height: 320)
        let filter = try RecordingSources.shared.filter(for: settings).0
        let config = SCStreamConfiguration(); config.width = 420; config.height = 320; config.showsCursor = false
        config.sourceRect = settings.area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        try await Task.sleep(for: .milliseconds(400))
        let before = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let center = try #require(NSBitmapImageRep(cgImage: before).colorAt(x: 210, y: 160)?.usingColorSpace(.sRGB))
        try #require(center.greenComponent > center.redComponent + 0.2 && center.greenComponent > center.blueComponent + 0.2, "The solid green test window must be visible before comparing capture pixels")
        pet.reveal(); try await Task.sleep(for: .milliseconds(150))
        let after = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let a = NSBitmapImageRep(cgImage: before), b = NSBitmapImageRep(cgImage: after)
        var differences = 0
        for y in stride(from: 10, to: 310, by: 4) { for x in stride(from: 10, to: 410, by: 4) {
            let ac = try #require(a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)), bc = try #require(b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            if abs(ac.redComponent - bc.redComponent) + abs(ac.greenComponent - bc.greenComponent) + abs(ac.blueComponent - bc.blueComponent) > 0.04 { differences += 1 }
        } }
        #expect(differences == 0, "The animated pet and its bubble must not change any captured pixels")
        let screenshots = try await RecordingScreenshotService.capture(windowID: CGWindowID(window.windowNumber), saveTo: document)
        let screenshot = try #require(screenshots.first)
        #expect(screenshot.error == nil); #expect(screenshot.png != nil); #expect(screenshot.footageID != nil)
        let assets = try document.container.mainContext.fetch(FetchDescriptor<ImportedAsset>())
        #expect(assets.count == 1); #expect(assets.first?.captureMetadata != nil)
        await document.close()
    }
}
