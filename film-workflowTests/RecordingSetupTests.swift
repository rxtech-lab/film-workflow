import AppKit
import AVFoundation
import SwiftData
import SwiftUI
import Testing
import RxPet
import VideoEditorCore
@testable import film_workflow

@MainActor @Suite("Recording setup and multi-window tracks", .serialized)
struct RecordingSetupTests {
    @Test func everySelectedWindowIsNamedAndCanBeDeselectedInTheToolbar() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let catalog = RecordingSources()
        catalog.windows = [
            .init(id: "101", name: "Safari — Product Demo", kind: "window"),
            .init(id: "102", name: "Keynote — Presentation", kind: "window"),
            .init(id: "103", name: "Notes — Speaker Notes", kind: "window")
        ]
        var settings = RecordingSettings(); settings.sourceKind = .window; settings.selectedWindowIDs = ["103", "101", "102"]
        let host = NSHostingView(rootView: SelectedSourcesHarness(settings: settings, catalog: catalog))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 180), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let nodes = hostedAccessibilityDescendants(host)
        for source in catalog.windows {
            let node = try #require(nodes.first { $0.accessibilityIdentifier() == "recording.selectedSource.\(source.id)" })
            #expect((node.accessibilityValue() as? String ?? node.accessibilityLabel()) == source.name)
        }
        let deselect = try #require(nodes.first { $0.accessibilityIdentifier() == "recording.deselectSource.101" })
        #expect(deselect.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(100))
        let ids = hostedAccessibilityDescendants(host).compactMap { $0.accessibilityIdentifier() }
        #expect(!ids.contains("recording.selectedSource.101"))
        #expect(ids.contains("recording.selectedSource.102") && ids.contains("recording.selectedSource.103"))
        // An unavailable selection stays listed so it can be removed.
        settings.selectedWindowIDs = ["103", "404", "102"]
        let selected = RecordingSelectedSourcesView.selections(settings: settings, catalog: catalog)
        #expect(selected.map(\.id) == ["103", "404", "102"])
        #expect(selected[1].name.contains("Unavailable window"))
    }

    @Test func recordingPetsFollowEachTargetAndWaitForCaptureExclusion() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let indicators = RecordingPetIndicators()
        let catalog = RecordingSources.shared
        let visible = try #require(NSScreen.main?.visibleFrame)
        var targets = [
            RecordingPetTarget(id: "one", name: "First Window", frame: CGRect(x: visible.minX + 40, y: visible.minY + 100, width: 300, height: 300)),
            RecordingPetTarget(id: "two", name: "Second Window", frame: CGRect(x: visible.minX + 400, y: visible.minY + 100, width: 300, height: 300))
        ]
        indicators.prepare(targets: targets)
        defer { indicators.dismiss() }
        let ids = indicators.windowIDs
        #expect(ids.count == 2)
        #expect(ids.isSubset(of: catalog.excludedWindowIDs))
        #expect(ids.isSubset(of: catalog.passThroughWindowIDs))
        let windows = NSApp.windows.filter { UInt32(exactly: $0.windowNumber).map(ids.contains) == true }
        #expect(windows.count == 2)
        indicators.update(targets: targets, status: .recording, mood: nil, message: nil, appliedExclusions: [], requiresExclusion: true)
        #expect(windows.allSatisfy { $0.alphaValue == 0 })
        indicators.update(targets: targets, status: .recording, mood: nil, message: nil, appliedExclusions: [try #require(ids.first)], requiresExclusion: true)
        #expect(windows.filter { $0.alphaValue == 1 }.count == 1)
        indicators.update(targets: targets, status: .recording, mood: nil, message: nil, appliedExclusions: ids, requiresExclusion: true)
        #expect(windows.allSatisfy { $0.alphaValue == 1 && $0.ignoresMouseEvents })
        try await Task.sleep(for: .milliseconds(100))
        let first = try #require(windows.first { window in
            hostedAccessibilityDescendants(window.contentView as Any).contains { $0.accessibilityLabel()?.contains("First Window") == true }
        })
        let oldFrame = first.frame
        targets[0] = .init(id: "one", name: "First Window", frame: targets[0].frame.offsetBy(dx: 0, dy: 100))
        indicators.update(targets: targets, status: .paused, mood: nil, message: nil, appliedExclusions: ids, requiresExclusion: true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(first.frame != oldFrame)
        #expect(hostedAccessibilityDescendants(first.contentView as Any).contains { $0.accessibilityLabel()?.contains("Paused · First Window") == true })
        indicators.update(targets: [targets[0]], status: .recording, mood: nil, message: nil, appliedExclusions: ids, requiresExclusion: true)
        #expect(windows.filter { $0.alphaValue == 1 }.count == 1)
        indicators.prepare(targets: [targets[0]])
        #expect(indicators.windowIDs.count == 1)
        #expect(ids.subtracting(indicators.windowIDs).isDisjoint(with: catalog.excludedWindowIDs))
        indicators.dismiss()
        #expect(ids.isDisjoint(with: catalog.excludedWindowIDs))
        #expect(ids.isDisjoint(with: catalog.passThroughWindowIDs))
    }

    @Test func legacySettingsRetainPreferencesAndWindow() throws {
        var value = RecordingSettings()
        value.sourceKind = .window; value.sourceID = "42"; value.fps = 30; value.countdown = 7
        value.cameraIDs = ["camera"]; value.applicationBundleIDs = ["example.app"]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object.removeValue(forKey: "selectedWindowIDs")
        let decoded = try JSONDecoder().decode(RecordingSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.selectedWindowIDs == ["42"])
        #expect(decoded.fps == 30 && decoded.countdown == 7)
        #expect(decoded.cameraIDs == ["camera"] && decoded.applicationBundleIDs == ["example.app"])
        var selected = decoded
        selected.selectedWindowIDs = ["43", "42", "43", ""]
        let restored = try JSONDecoder().decode(RecordingSettings.self, from: JSONEncoder().encode(selected))
        #expect(restored.selectedWindowIDs == ["43", "42"])
        #expect(restored.sourceID == "43")
        selected.selectedWindowIDs = []
        #expect(selected.sourceID.isEmpty && selected.captureSourceIDs.isEmpty)
    }

    @Test func permissionsRefreshThroughPartialGrantAndRevocation() {
        var granted = Set<RecordingPermission>()
        let permissions = RecordingPermissions(probe: { granted })
        #expect(!permissions.baseGranted)
        granted = [.screen]; permissions.refresh(); #expect(!permissions.baseGranted)
        granted.insert(.input); permissions.refresh(); #expect(permissions.baseGranted)
        var settings = RecordingSettings()
        #expect(permissions.allows(settings))
        settings.cameraIDs = ["camera"]
        #expect(!permissions.allows(settings))
        granted.insert(.camera); permissions.refresh(); #expect(permissions.allows(settings))
        #expect(!permissions.allows(settings, replay: true))
        granted.insert(.accessibility); permissions.refresh(); #expect(permissions.allows(settings, replay: true))
        granted.remove(.input); permissions.refresh(); #expect(!permissions.baseGranted)
        settings.sourceKind = .device
        #expect(RecordingPermissions.required(for: settings).contains(.microphone))
    }

    @Test func inspectorPermissionGuideKeepsAllPermissionsAvailableAfterBaseGrant() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        var granted = Set<RecordingPermission>()
        let permissions = RecordingPermissions(probe: { granted })
        let host = NSHostingView(rootView: RecordingPermissionGuide(showsAllPermissions: true, permissions: permissions))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 1600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func controlIDs() -> Set<String> { Set(hostedAccessibilityDescendants(host).compactMap { $0.accessibilityIdentifier() }) }
        for permission in RecordingPermission.allCases {
            #expect(controlIDs().contains("recording.permissions.\(permission.rawValue).allow"))
            #expect(controlIDs().contains("recording.permissions.\(permission.rawValue).settings"))
        }
        granted = [.screen, .input]; permissions.refresh()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(!controlIDs().contains("recording.permissions.screen.allow"))
        for permission in [RecordingPermission.camera, .microphone, .accessibility] {
            #expect(controlIDs().contains("recording.permissions.\(permission.rawValue).allow"))
        }
    }

    @Test func areaGeometryHandlesDirectionsAndMultipleDisplays() {
        let display = CGRect(x: -1600, y: -400, width: 1600, height: 1000)
        let expected = CGRect(x: -1500, y: -300, width: 700, height: 500)
        for start in [CGPoint(x: -1500, y: -300), CGPoint(x: -800, y: -300), CGPoint(x: -800, y: 200), CGPoint(x: -1500, y: 200)] {
            let end = CGPoint(x: start.x == -1500 ? -800 : -1500, y: start.y == -300 ? 200 : -300)
            #expect(RecordingSelectionGeometry.drag(from: start, to: end, within: display) == expected)
        }
        #expect(RecordingSelectionGeometry.validArea(expected, in: display))
        #expect(!RecordingSelectionGeometry.validArea(CGRect(x: -1, y: 0, width: 100, height: 100), in: display))
        #expect(!RecordingSelectionGeometry.validArea(CGRect(x: 0, y: 0, width: 1, height: 1), in: display))
        let flipped = RecordingSelectionGeometry.flip(expected, desktopTop: 1080)
        #expect(RecordingSelectionGeometry.flip(flipped, desktopTop: 1080) == expected)
    }

    @Test func toolbarMovesBelowAreaAndFallsBackAbove() {
        let visible = CGRect(x: -1600, y: 0, width: 1600, height: 1000)
        let size = CGSize(width: 1100, height: 116)
        let middle = CGRect(x: -1400, y: 400, width: 800, height: 300)
        let below = RecordingSelectionGeometry.toolbarFrame(size: size, area: middle, visibleFrame: visible)
        #expect(below.maxY == middle.minY - 12)
        let bottom = CGRect(x: -1550, y: 20, width: 600, height: 300)
        let above = RecordingSelectionGeometry.toolbarFrame(size: size, area: bottom, visibleFrame: visible)
        #expect(above.minY == bottom.maxY + 12)
        #expect(visible.contains(above))
        #expect(visible.contains(RecordingSelectionGeometry.toolbarFrame(size: CGSize(width: 2000, height: 116), area: middle, visibleFrame: visible)))
    }

    @Test func setupDoesNotCreateRecordingOrChangeSettings() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Setup-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let project = ScreenRecordingProject(name: "Setup")
        document.container.mainContext.insert(project)
        let settings = project.settings, operation = RecordingSession.shared.operationID
        let setup = RecordingSetup.shared
        setup.open(project: project, document: document)
        #expect(setup.isPresented)
        #expect(!RecordingSession.shared.isActive)
        #expect(RecordingSession.shared.operationID == operation)
        setup.pending.countdown = 9
        let other = ScreenRecordingProject(name: "Other")
        setup.open(project: other, document: document)
        #expect(setup.project?.id == project.id)
        setup.cancel()
        #expect(!setup.isPresented && project.settings == settings)
        #expect(project.takes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("Media/ScreenRecordings/\(project.id)").path))
        await document.close()
    }

    @Test func quickRecordingReusesTheLatestProjectAndDoesNotStartCapture() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuickRecording-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let context = document.container.mainContext
        let older = ScreenRecordingProject(name: "Older"), latest = ScreenRecordingProject(name: "Latest")
        var settings = RecordingSettings(); settings.mode = .actions; settings.countdown = 7
        latest.settings = settings
        older.updatedAt = Date(timeIntervalSince1970: 1); latest.updatedAt = Date(timeIntervalSince1970: 2)
        context.insert(older); context.insert(latest); try context.save()
        let setup = RecordingSetup.shared
        let selected = try setup.openQuickRecording(in: document)
        #expect(selected.id == latest.id)
        #expect(setup.project?.id == latest.id && setup.document?.id == document.id)
        #expect(setup.pending.mode == .content && setup.pending.countdown == 7)
        #expect(latest.settings == settings)
        #expect(!RecordingSession.shared.isActive && latest.takes.isEmpty)
        #expect(try setup.openQuickRecording(in: document).id == latest.id)
        #expect(try context.fetchCount(FetchDescriptor<ScreenRecordingProject>()) == 2)
        setup.cancel()
        await document.close()
    }

    @Test func quickRecordingCreatesAProjectForAnEmptyFilm() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FirstQuickRecording-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let project = try RecordingSetup.shared.openQuickRecording(in: document)
        #expect(project.modelContext === document.container.mainContext)
        #expect(project.takes.isEmpty)
        #expect(RecordingSetup.shared.isPresented && !RecordingSession.shared.isActive)
        #expect(try document.container.mainContext.fetchCount(FetchDescriptor<ScreenRecordingProject>()) == 1)
        RecordingSetup.shared.cancel()
        await document.close()
    }

    @Test func idleMenuQuickRecordingOpensSetupInTheActiveFilm() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuickMenu-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let documents = ProjectDocumentController.shared
        let previous = documents.activeDocument
        documents.activeDocument = document
        defer { documents.activeDocument = previous; RecordingSetup.shared.cancel() }
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let host = NSHostingView(rootView: VStack { RecordingMenuBarControls() })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let button = try #require(hostedAccessibilityDescendants(host).first { $0.accessibilityIdentifier() == "recording.quickStart" })
        #expect(button.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(100))
        #expect(RecordingSetup.shared.isPresented)
        #expect(RecordingSetup.shared.document?.id == document.id)
        #expect(!RecordingSession.shared.isActive)
        RecordingSetup.shared.cancel()
        await document.close()
    }

    @Test func windowsKeepIndependentCursorPresentationAndOneEditGroup() throws {
        var firstPresentation = RecordingClipPresentation()
        firstPresentation.pointer = [.init(time: 1, x: 0.2, y: 0.3, clicked: true)]
        var secondPresentation = RecordingClipPresentation()
        secondPresentation.pointer = [.init(time: 1, x: 0.8, y: 0.9)]
        let screens: [RecordingComponent] = [
            .init(role: .screen, name: "First", filePath: "first.mov", duration: 2, width: 800, height: 600, sourceID: "1", presentation: firstPresentation),
            .init(role: .screen, name: "Second", filePath: "second.mov", start: 0.1, duration: 5, width: 1000, height: 800, sourceID: "2", presentation: secondPresentation)
        ]
        let cursors = RecordingComponentBuilder.cursors(for: screens, path: "cursor.png", defaults: .init())
        #expect(cursors[0].duration == 2 && cursors[1].start == 0.1)
        #expect(cursors[1].presentation?.pointer == secondPresentation.pointer)
        let take = RecordingTake(name: "Two windows"); take.duration = 5.1; take.components = screens + cursors
        let sequence = SequenceProject(name: "Timeline")
        let ids = try RecordingTimelineService.insert(take: take, into: sequence, at: 3)
        #expect(ids.count == 4)
        let clips = sequence.timeline.allClips
        #expect(Set(clips.compactMap(\.linkGroupID)).count == 1)
        #expect(Set(clips.compactMap(\.recordingInstanceID)).count == 2)
        // Both screens are pictures; the second cannot share the first's lane.
        for screen in clips.filter({ $0.recording?.role == .screen }) {
            #expect(sequence.timeline.track(containing: screen.id)?.kind == .video)
        }
        for cursor in clips.filter({ $0.recording?.role == .cursor }) {
            #expect(sequence.timeline.track(containing: cursor.id)?.kind == .overlay)
        }
        #expect(!sequence.timeline.tracks.contains { $0.name.hasPrefix("R") })
        for cursor in clips.filter({ $0.recording?.role == .cursor }) {
            let screen = try #require(clips.first { $0.recording?.role == .screen && $0.recordingInstanceID == cursor.recordingInstanceID })
            #expect(cursor.start == screen.start && cursor.duration == screen.duration)
            #expect(cursor.recording?.pointer == screen.recording?.pointer)
        }
        _ = try RecordingTimelineService.insert(take: take, into: sequence, at: 10)
        #expect(Set(sequence.timeline.allClips.compactMap(\.recordingInstanceID)).count == 4)
        let preview = try RecordingTimelineService.previewTimeline(take)
        #expect(preview.allClips.filter { $0.recording?.role == .screen }.count == 1)
    }

    @Test func oldAndNewCheckpointsDecode() throws {
        let sample = RecordingPointerSample(time: 1, x: 0.4, y: 0.7)
        let checkpoint = RecordingCheckpoint(operationID: UUID(), projectID: UUID(), phase: "recording", elapsed: 3,
            settings: RecordingSettings(), actions: [], components: [], pointer: [sample], shortcuts: [], pointersBySource: ["1": [sample]])
        let data = try JSONEncoder().encode(checkpoint)
        #expect(try JSONDecoder().decode(RecordingCheckpoint.self, from: data).pointersBySource?["1"] == [sample])
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "pointersBySource")
        let legacy = try JSONDecoder().decode(RecordingCheckpoint.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.pointersBySource == nil && legacy.pointer == [sample])
    }

    @Test func endingOneWindowDoesNotExtendItsVideoToTheSharedClock() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EndedWindow-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = RecordingClock(); clock.reset()
        let writer = RecordingMediaWriter(url: url, video: true, clock: clock)
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel)
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        writer.append(try #require(sample))
        try await Task.sleep(for: .milliseconds(200))
        writer.endSegment()
        let endedAt = clock.elapsed
        try await Task.sleep(for: .milliseconds(350))
        let result = try #require(try await writer.finish())
        #expect(abs(result.start + result.duration - endedAt) < 0.1)
        #expect(clock.elapsed - (result.start + result.duration) > 0.25)
    }

    @Test func windowSelectionFollowsStackingAndLeavesLowerWindowsUncovered() async throws {
        let screen = try #require(NSScreen.main)
        let visible = screen.visibleFrame
        let lower = NSWindow(contentRect: CGRect(x: visible.minX + 30, y: visible.minY + 30, width: visible.width * 0.6, height: visible.height * 0.6), styleMask: .borderless, backing: .buffered, defer: false)
        let upper = NSWindow(contentRect: lower.frame.offsetBy(dx: 120, dy: 100), styleMask: .borderless, backing: .buffered, defer: false)
        lower.isReleasedWhenClosed = false; upper.isReleasedWhenClosed = false
        var orderedWindows = [upper, lower]
        let sources = RecordingSources.shared
        let overlays = RecordingSelectionOverlays(windowList: {
            orderedWindows.map { window in
                [kCGWindowNumber as String: UInt32(window.windowNumber), kCGWindowLayer as String: 0,
                 kCGWindowBounds as String: RecordingSelectionGeometry.flip(window.frame, desktopTop: RecordingSelectionOverlays.desktopTop).dictionaryRepresentation]
            }
        })
        let oldWindows = sources.windows, oldPending = RecordingSetup.shared.pending
        defer {
            overlays.dismiss(); lower.orderOut(nil); upper.orderOut(nil)
            sources.windows = oldWindows; RecordingSetup.shared.pending = oldPending
        }
        sources.windows = [lower, upper].map { window in
            RecordingSource(id: String(window.windowNumber), name: "Selection test", kind: "window", windowID: UInt32(window.windowNumber), frame: RecordingSelectionGeometry.flip(window.frame, desktopTop: RecordingSelectionOverlays.desktopTop))
        }
        lower.orderFrontRegardless(); upper.orderFrontRegardless()
        var settings = RecordingSettings(); settings.sourceKind = .window
        RecordingSetup.shared.pending = settings
        overlays.showSetup(settings: settings)
        let panel = try #require(NSApp.windows.first { window in
            guard window.isVisible, let id = UInt32(exactly: window.windowNumber) else { return false }
            return overlays.windowIDs.contains(id)
        })
        #expect(panel.frame == upper.frame.intersection(screen.frame))
        let exposedLowerPoint = CGPoint(x: lower.frame.minX + 20, y: lower.frame.minY + 20)
        #expect(!panel.frame.contains(exposedLowerPoint))
        #expect(panel.frame.contains(CGPoint(x: upper.frame.midX, y: upper.frame.midY)))

        // A native click can raise this uncovered window; tracking must follow
        // without changing the existing selection or requiring a setup refresh.
        lower.orderFrontRegardless()
        orderedWindows = [lower, upper]
        try await Task.sleep(for: .milliseconds(300))
        #expect(panel.frame == lower.frame.intersection(screen.frame))
        #expect(RecordingSetup.shared.pending.selectedWindowIDs.isEmpty)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: panel.frame.width / 2, y: panel.frame.height / 2), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        panel.contentView?.mouseDown(with: click)
        #expect(RecordingSetup.shared.pending.selectedWindowIDs == [String(lower.windowNumber)])

        lower.setFrameOrigin(CGPoint(x: lower.frame.minX + 35, y: lower.frame.minY + 25))
        try await Task.sleep(for: .milliseconds(300))
        #expect(panel.frame == lower.frame.intersection(screen.frame))
        overlays.hide()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!panel.isVisible)
    }

    @Test func startingRecordingDismissesSelectionOverlaysAndKeepsThePetVisibleWithoutTheToolbar() throws {
        let overlays = RecordingSelectionOverlays.shared
        let pets = RecordingPetIndicators()
        defer { overlays.dismiss(); pets.dismiss() }
        var settings = RecordingSettings(); settings.sourceKind = .area
        settings.area = CGRect(x: 50, y: 50, width: 300, height: 200)
        overlays.showSetup(settings: settings)
        let ids = overlays.windowIDs
        #expect(!ids.isEmpty)
        let selectionWindows = NSApp.windows.filter { UInt32(exactly: $0.windowNumber).map(ids.contains) == true }
        #expect(selectionWindows.contains { $0.isVisible })
        let targets = [RecordingPetTarget(id: "area", name: "Selected Area", frame: try #require(NSScreen.main?.visibleFrame))]
        pets.prepare(targets: targets)
        let petIDs = pets.windowIDs
        let petWindow = try #require(NSApp.windows.first { UInt32(exactly: $0.windowNumber).map(petIDs.contains) == true })
        pets.update(targets: targets, status: .recording, mood: nil, message: nil, appliedExclusions: petIDs, requiresExclusion: true)

        RecordingSetup.shared.recordingStarted()
        // The controls moved beside the pet; the wide toolbar no longer sits on
        // top of what is being recorded.
        #expect(!RecordingWindows.shared.isToolbarVisible)
        #expect(overlays.windowIDs.isEmpty)
        #expect(selectionWindows.allSatisfy { !$0.isVisible })
        #expect(petWindow.isVisible && petWindow.alphaValue == 1 && petWindow.ignoresMouseEvents)
        pets.update(targets: targets, status: .paused, mood: nil, message: nil, appliedExclusions: petIDs, requiresExclusion: true)
        #expect(overlays.windowIDs.isEmpty)
        #expect(petWindow.isVisible && petWindow.alphaValue == 1)
        #expect(RecordingSources.shared.excludedWindowIDs.isDisjoint(with: ids))
        #expect(RecordingSources.shared.excludedWindowIDs.isSuperset(of: petIDs))
        #expect(RecordingSources.shared.passThroughWindowIDs.isSuperset(of: petIDs))
    }
}

private struct SelectedSourcesHarness: View {
    @State var settings: RecordingSettings
    let catalog: RecordingSources
    var body: some View {
        RecordingSelectedSourcesView(sources: RecordingSelectedSourcesView.selections(settings: settings, catalog: catalog), width: 640) { id in
            settings.selectedWindowIDs.removeAll { $0 == id }
        }.padding(20)
    }
}
