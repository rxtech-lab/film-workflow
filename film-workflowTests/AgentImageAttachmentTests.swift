import Foundation
import RxAgentSDK
import SwiftData
import Testing
@testable import film_workflow

@MainActor
@Suite("Agent image attachment persistence")
struct AgentImageAttachmentTests {
    @Test("An attachment-only message preserves images, files, and folders after reopening")
    func attachmentOnlyTurnRoundTrips() throws {
        let schema = Schema([film_workflow.AgentThread.self, film_workflow.AgentMessage.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        ])
        let context = ModelContext(container)
        let thread = film_workflow.AgentThread(title: "Image reference")
        context.insert(thread)
        let sdkThread = RxAgentSDK.AgentThread()
        let image = AgentAttachment(kind: .image(Data([1, 2, 3]), mimeType: "image/png"), label: "Reference.png")
        let attachments: [AgentAttachment] = [image, .file(URL(filePath: "/tmp/notes.txt")), .file(URL(filePath: "/tmp/Footage"))]
        sdkThread.appendUserMessage("", attachments: attachments)
        AgentTranscriptStore.saveTranscript(from: sdkThread, to: thread, context: context)
        try context.save()

        let reopenedContext = ModelContext(container)
        let reopened = try #require(try reopenedContext.fetch(FetchDescriptor<film_workflow.AgentThread>()).first)
        let loaded = AgentTranscriptStore.load(reopened)
        #expect(loaded.messages.count == 1)
        #expect(loaded.messages.first?.attachments == attachments)
        #expect(loaded.messages.first?.id == sdkThread.messages.first?.id)
        // The row fallback must also preserve image-only messages, even without
        // the transcript snapshot (for example, after interrupted persistence).
        reopened.transcriptJSON = nil
        #expect(AgentTranscriptStore.load(reopened).messages.first?.attachments == attachments)
    }
}
