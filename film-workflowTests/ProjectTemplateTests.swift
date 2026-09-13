import AppKit
import Foundation
import RxAgentSDK
import SwiftData
import Testing
import VideoEditorCore
@testable import film_workflow

@Suite("Project templates", .serialized) @MainActor
struct ProjectTemplateTests {
    func template() -> ProjectTemplateDefinition {
        var value = ProjectTemplateDefinition()
        value.prompt = "Make a landscape video"; value.videoStyle = "Warm, cinematic"
        value.footageRequirements = [.init(id: "wide", title: "Wide shot", mediaType: "image", instructions: "Provide a landscape still")]
        value.shots = [.init(id: "opening", title: "Opening", instructions: "Open wide", durationSeconds: 2, footageRequirementId: "wide")]
        return value
    }
    @Test("Portable definitions reject paths and broken references")
    func portability() throws {
        let value = template()
        #expect(try ProjectTemplateDefinition.decode(Data(value.json().utf8)) == value)
        var invalid = value; invalid.shots[0].footageRequirementId = "missing"
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = value; invalid.prompt = "Read /Users/person/private.mov"
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = value; invalid.version = 2
        #expect(throws: (any Error).self) { try invalid.validate() }
    }
    @Test("Cards retain full, distinct template content after transcript reload")
    func durableCards() throws {
        let container = try ModelContainer(for: AppModelContainer.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let thread = AgentThread(title: "Templates"); container.mainContext.insert(thread)
        var definition = template(); definition.prompt = String(repeating: "A reusable direction. ", count: 80)
        for id in ["first", "second"] {
            let payload = MarketplaceCardPayload(marketplaceItem: .init(id: id, kind: .projectTemplate, category: "test", title: id), definition: definition, status: "draft")
            let row = AgentMessage(role: .assistant, content: "", kind: .tool, toolName: "marketplace_show", toolArgs: "{}", toolResult: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self), toolStatus: .ok, toolCallId: id)
            AgentTranscriptStore.attach(row, to: thread, context: container.mainContext)
        }
        try container.mainContext.save()
        let transcript = AgentTranscriptStore.load(thread)
        let payloads = transcript.messages.flatMap(\.blocks).compactMap { block -> MarketplaceCardPayload? in
            if case .toolCall(let call) = block { return .decode(call.result) }; return nil
        }
        #expect(payloads.map(\.marketplaceItem.id) == ["first", "second"])
        #expect(payloads.allSatisfy { $0.definition?.prompt == definition.prompt })
    }
    @Test("Admin tools are withheld and direct calls fail without authentication")
    func adminAccess() async throws {
        MarketplaceAuthoringService.shared.clearAccess()
        #expect(!AgentToolPolicy.allows("marketplace_create", policy: .direct))
        #expect(!MCPToolRegistry.allDescriptors().contains { $0.name == "marketplace_publish" })
        let service = MarketplaceAuthoringService(authenticated: { false }, transport: { _, _, _ in throw MarketplaceAuthoringError.adminRequired })
        #expect(await service.refreshAccess() == false)
        await #expect(throws: (any Error).self) { try await service.requireAdmin() }
    }
    @Test("A collecting application resumes one new sequence and preserves existing edits")
    func applicationRecovery() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TemplateTests-\(UUID().uuidString).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        var document = try ProjectDocument.create(at: url)
        let original = SequenceProject(name: "Original edit"); document.container.mainContext.insert(original); try document.container.mainContext.save()
        let oldTimeline = original.timeline
        var state = ProjectTemplateApplication(id: UUID().uuidString, itemId: UUID().uuidString, title: "Travel", template: template(), sequenceId: UUID())
        state = try await ProjectTemplateService.advance(state, expectedItemId: state.itemId, document: document, bindings: [:], resolveDependencies: false)
        #expect(state.missingRequirements == ["wide"])
        #expect(try document.container.mainContext.fetchCount(FetchDescriptor<SequenceProject>()) == 2)
        let png = url.appendingPathComponent("sample.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: png)
        let asset = try await MediaImporter.importCopy(url: png, kind: .image, name: "Landscape", groupID: nil, storage: document.storage, context: document.container.mainContext)
        try document.container.mainContext.save()
        state = try await ProjectTemplateService.advance(state, expectedItemId: state.itemId, document: document, bindings: ["wide": "imported:\(asset.id)"], resolveDependencies: false)
        #expect(state.state == "ready")
        #expect(original.timeline == oldTimeline)
        let sequence = try MCPLibraryHandlers.fetchSequence(id: state.sequenceId.uuidString, context: document.container.mainContext)
        #expect(sequence.timeline.allClips.count == 1)
        await document.close(); document = try ProjectDocument.open(url)
        let saved = try JSONDecoder().decode(ProjectTemplateApplication.self, from: Data(contentsOf: ProjectTemplateService.applicationsDirectory(document).appendingPathComponent("\(state.id).json")))
        let resumed = try await ProjectTemplateService.advance(saved, expectedItemId: state.itemId, document: document, bindings: [:], resolveDependencies: false)
        #expect(resumed.sequenceId == state.sequenceId)
        #expect(try document.container.mainContext.fetchCount(FetchDescriptor<SequenceProject>()) == 2)
        await document.close()
    }
}
