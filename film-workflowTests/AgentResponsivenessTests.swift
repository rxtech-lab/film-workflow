import Foundation
import Testing

@testable import film_workflow

@Suite("Agent file responsiveness")
struct AgentResponsivenessTests {
    @Test("File operations leave the main thread and concurrent edits retain every change")
    @MainActor
    func concurrentEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let onMain = try await RemotionFileWorker.shared.perform {
            try RemotionTools.writeFile(projectDir: directory, path: "src/test.tsx", content: "one two three")
            return Thread.isMainThread
        }
        #expect(!onMain)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for word in ["one", "two", "three"] {
                group.addTask {
                    _ = try await RemotionFileWorker.shared.perform {
                        try RemotionTools.editFile(projectDir: directory, path: "src/test.tsx",
                                                   oldString: word, newString: word.uppercased())
                    }
                }
            }
            try await group.waitForAll()
        }
        let text = try await RemotionFileWorker.shared.perform {
            try RemotionTools.readFile(projectDir: directory, path: "src/test.tsx").text
        }
        #expect(text == "ONE TWO THREE")
    }
}
