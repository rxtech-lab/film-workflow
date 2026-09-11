import AVFoundation
import Foundation
import SwiftData
import Testing
import VideoEditorCore

@testable import film_workflow

@Suite("Sequence render completion", .serialized)
@MainActor
struct SequenceRenderProgressTests {
    @Test("Completed exports cannot restore progress or regress from finalizing", arguments: [false, true])
    func completionStopsProgress(saveInFilm: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SequenceRenderProgress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try ProjectDocument.create(at: root.appendingPathComponent("Test.rxfilmstudio"))
        let context = document.container.mainContext
        let audioURL = root.appendingPathComponent("tone.caf")
        try writeTone(to: audioURL)
        let audio = ImportedAsset(name: "Tone", kind: .audio, originalPath: audioURL.path)
        audio.relativePath = try document.storage.copyFile(from: audioURL, kind: .imported, fallbackExtension: "caf")
        audio.durationSeconds = 1
        context.insert(audio)

        let sequence = SequenceProject(name: "Completion test")
        var timeline = Timeline(width: 320, height: 180, fps: 30)
        let track = try #require(timeline.tracks.first { $0.kind == .audio })
        try TimelineEditor.insert(&timeline, clip: Clip(
            source: ClipSource(id: DocumentMediaResolver.sourceID(.imported, audio.id), kind: .audio, displayName: "Tone"),
            start: 0, duration: 1
        ), on: track.id)
        sequence.timeline = timeline
        context.insert(sequence)
        try context.save()

        let state = EditorWindowState()
        var updates: [SequenceRenderProgress] = []
        var completed = false
        var updatesAfterCompletion = 0
        let output = try await SequenceRenderService.render(
            sequence: sequence, document: document,
            options: .init(video: nil, audio: .aac),
            destination: saveInFilm ? .film : .folder(root)
        ) { progress in
            if completed { updatesAfterCompletion += 1 }
            updates.append(progress)
            state.renderProgress = progress
        }
        completed = true
        state.renderProgress = nil
        // Let queued main-actor progress callbacks run, as they do after the
        // editor's render task returns and dismisses its sheet.
        try await Task.sleep(for: .milliseconds(200))

        #expect(FileManager.default.fileExists(atPath: output.url.path))
        #expect(updatesAfterCompletion == 0)
        #expect(state.renderProgress == nil)
        let finalizing = try #require(updates.firstIndex(of: .finalizing))
        #expect(finalizing == updates.count - 1)
        #expect(SequenceRenderService.renders(for: sequence, context: context).count == (saveInFilm ? 1 : 0))
        await document.close()
    }

    private func writeTone(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)
        for index in 0..<Int(buffer.frameLength) {
            samples[0][index] = Float(sin(2 * .pi * 440 * Double(index) / 48_000)) * 0.1
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
