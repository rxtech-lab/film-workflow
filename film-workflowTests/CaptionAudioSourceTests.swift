import AVFoundation
import SwiftData
import Testing
import VideoEditorCore
@testable import film_workflow

@Suite("Captions for the film's own audio", .serialized) @MainActor
struct CaptionAudioSourceTests {
    private func document() throws -> ProjectDocument {
        try ProjectDocument.create(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionAudioSource-\(UUID()).rxfilmstudio"))
    }

    /// Three seconds of tone, which is enough for a duration to be read back.
    private func writeTone(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(sin(2 * .pi * 440 * Double(index) / 48_000)) * 0.1
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    private func take(in document: ProjectDocument, name: String = "Song") throws -> GeneratedMusic {
        let context = document.container.mainContext
        let project = MusicProject(name: name)
        context.insert(project)
        let path = "\(ProjectStorage.MediaKind.music.rawValue)/\(UUID()).wav"
        try writeTone(to: document.storage.absoluteURL(for: path))
        let take = GeneratedMusic(audioFilePath: path, lyricsText: nil, project: project)
        take.durationSeconds = 3
        context.insert(take)
        try context.save()
        return take
    }

    /// Referenced in place, the way the import sheet records a file the user
    /// chose not to copy in.
    private func importedAudio(in document: ProjectDocument) throws -> (ImportedAsset, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Referenced-\(UUID()).wav")
        try writeTone(to: url)
        let asset = ImportedAsset(name: "Interview", kind: .audio, originalPath: url.path)
        asset.durationSeconds = 3
        document.container.mainContext.insert(asset)
        try document.container.mainContext.save()
        return (asset, url)
    }

    @Test("Only audio is offered, and a video import never is")
    func entriesListRecordings() throws {
        let document = try document()
        defer { Task { @MainActor in await document.close() } }
        let context = document.container.mainContext
        let take = try take(in: document)
        let (asset, url) = try importedAudio(in: document)
        defer { try? FileManager.default.removeItem(at: url) }
        let movie = ImportedAsset(name: "B-roll", kind: .video, originalPath: "/tmp/broll.mov")
        context.insert(movie)

        let entries = CaptionAudioSource.entries(
            music: try context.fetch(FetchDescriptor<GeneratedMusic>()),
            imported: try context.fetch(FetchDescriptor<ImportedAsset>())
        )
        #expect(entries.map(\.id) == [DocumentMediaResolver.sourceID(.music, take.id),
                                      DocumentMediaResolver.sourceID(.imported, asset.id)])
        #expect(entries.first?.title == "Song · v1")
        #expect(entries.last?.title == "Interview")
        // The lyrics menu offers exactly the same recordings, by construction.
        #expect(MusicLyrics.targets(music: try context.fetch(FetchDescriptor<GeneratedMusic>()),
                                    imported: try context.fetch(FetchDescriptor<ImportedAsset>()))
            .map(\.id) == entries.map(\.id))
    }

    @Test("A music take gets one caption project, referenced in place and reused on the second ask")
    func prepareProjectIsIdempotent() async throws {
        let document = try document()
        defer { Task { @MainActor in await document.close() } }
        let context = document.container.mainContext
        let take = try take(in: document)
        let sourceID = DocumentMediaResolver.sourceID(.music, take.id)

        let captions = try await CaptionAudioSource.prepareProject(for: sourceID, context: context)
        #expect(captions.name == "Song · v1 captions")
        #expect(captions.lyricsSourceID == sourceID)
        // A take already lives in the package, so nothing is copied.
        #expect(!captions.ownsAudioFile)
        #expect(captions.audioFilePath == take.audioFilePath)
        #expect(captions.audioDurationMs == 3000)
        #expect(!captions.isNarrativeSourced)
        // Transcribing, not aligning: the audio came with no script.
        #expect(captions.referenceUnits.isEmpty)
        #expect(captions.activeSegmentCount == 0)

        let again = try await CaptionAudioSource.prepareProject(for: sourceID, context: context)
        #expect(again === captions)
        #expect(try context.fetch(FetchDescriptor<CaptionProject>()).count == 1)
        // The lyrics editor follows the same link, so it finds these captions
        // rather than starting a second project for the same recording.
        #expect(try await MusicLyrics.prepare(for: sourceID, context: context) === captions)
    }

    @Test("Referenced audio is copied in, and repointing a project drops the copy and its narrative source")
    func attachReplacesTheSource() async throws {
        let document = try document()
        defer { Task { @MainActor in await document.close() } }
        let context = document.container.mainContext
        let (asset, url) = try importedAudio(in: document)
        defer { try? FileManager.default.removeItem(at: url) }
        let importedID = DocumentMediaResolver.sourceID(.imported, asset.id)

        let captions = CaptionProject(name: "Untitled Captions")
        captions.sourceKindEnum = .generatedNarrative
        captions.sourceNarrativeName = "Opening"
        captions.sourceNarrativeID = UUID()
        captions.referenceUnits = [CaptionReferenceUnit(paragraphId: UUID(), speakerId: UUID(), order: 0, plainText: "Hello")]
        context.insert(captions)

        try await CaptionAudioSource.attach(importedID, to: captions, context: context)
        // The file sits outside the package, so the project takes a copy.
        #expect(captions.ownsAudioFile)
        #expect(captions.audioURL != url)
        #expect(FileManager.default.fileExists(atPath: captions.audioURL.path))
        #expect(captions.name == "Interview captions")
        #expect(!captions.isNarrativeSourced)
        #expect(captions.sourceNarrativeName.isEmpty)
        #expect(captions.sourceNarrativeID == nil)
        #expect(captions.referenceUnits.isEmpty)

        let copied = captions.audioFilePath
        let take = try take(in: document)
        try await CaptionAudioSource.attach(DocumentMediaResolver.sourceID(.music, take.id), to: captions, context: context)
        #expect(captions.audioFilePath == take.audioFilePath)
        #expect(!captions.ownsAudioFile)
        // The copy this project owned is not left behind in the package.
        #expect(!FileManager.default.fileExists(atPath: document.storage.absoluteURL(for: copied).path))
    }

    @Test("A recording another project already claims is played without stealing the link")
    func linkStaysWithTheFirstProject() async throws {
        let document = try document()
        defer { Task { @MainActor in await document.close() } }
        let context = document.container.mainContext
        let take = try take(in: document)
        let sourceID = DocumentMediaResolver.sourceID(.music, take.id)
        let first = try await CaptionAudioSource.prepareProject(for: sourceID, context: context)

        let second = CaptionProject(name: "Second pass")
        context.insert(second)
        try await CaptionAudioSource.attach(sourceID, to: second, context: context)

        #expect(second.audioFilePath == take.audioFilePath)
        #expect(second.lyricsSourceID == nil)
        #expect(try CaptionAudioSource.existingProject(for: sourceID, context: context) === first)
    }
}
