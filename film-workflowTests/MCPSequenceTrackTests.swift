import Foundation
import SwiftData
import Testing
import VideoEditorCore

@testable import film_workflow

@Suite("Sequence track tools", .serialized)
@MainActor
struct MCPSequenceTrackTests {
    private func payload(_ result: [String: Any]) throws -> [String: Any] {
        try #require(result["structuredContent"] as? [String: Any])
    }

    private func readTimeline(sequenceID: UUID, container: ModelContainer) async throws -> Timeline {
        let result = try payload(try await MCPToolRegistry.invoke(
            name: "sequence_get", arguments: ["sequence_id": sequenceID.uuidString], container: container
        ))
        let object = try #require(result["timeline"])
        return try JSONDecoder().decode(Timeline.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("Track creation is callable in conversations and Simple mode under either write policy")
    func toolAvailability() throws {
        for policy in AgentWritePolicy.allCases {
            for mode in [AgentThreadMode.conversation, .simpleMode(templateID: "company-intro-video")] {
                let descriptor = try #require(AgentToolPolicy.descriptors(policy: policy, mode: mode)
                    .first { $0.name == "sequence_add_track" })
                let properties = try #require(descriptor.inputSchema["properties"] as? [String: Any])
                #expect(properties["film"] != nil)
                #expect(descriptor.inputSchema["required"] as? [String] == ["sequence_id", "kind"])
                let kind = try #require(properties["kind"] as? [String: Any])
                #expect(kind["enum"] as? [String] == ["video", "audio", "overlay", "caption"])
                #expect(AgentToolPolicy.allows(descriptor.name, policy: policy, mode: mode))
            }
        }
    }

    // Caption lanes take cues rather than the imported footage this fixture
    // places, so they are covered by `captionTracks()` below instead. Zoom
    // lanes are made with the recording they belong to and are not on offer.
    @Test("Added tracks preserve the edit and accept clips through the returned ID",
          arguments: TrackKind.allCases.filter { $0 != .caption && $0 != .zoom })
    func addTrackAndClip(kind: TrackKind) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MCPSequenceTrack-\(UUID())")
        let document = try ProjectDocumentController.shared.createDocument(
            at: root.appendingPathComponent("Tracks.rxfilmstudio")
        )
        defer {
            Task {
                await ProjectDocumentController.shared.close(document)
                try? FileManager.default.removeItem(at: root)
            }
        }
        let context = document.container.mainContext
        // Explicit duration avoids loading media; the test exercises the same
        // source lookup and clip insertion that agent calls use.
        let sourceKind: SourceKind = kind == .audio ? .audio : .image
        let asset = ImportedAsset(name: "Footage", kind: kind == .audio ? .audio : .image, originalPath: "/unused")
        context.insert(asset)
        let source = ClipSource(
            id: DocumentMediaResolver.sourceID(.imported, asset.id), kind: sourceKind, displayName: asset.name
        )
        let sequence = SequenceProject(name: "Cut")
        var before = sequence.timeline
        before.width = 1280
        before.height = 720
        before.fps = 24
        before.backgroundHex = "#123456"
        // Only some kinds come with a new sequence; add the lane when this one
        // does not, so every case starts from a track that already exists.
        if !before.tracks.contains(where: { $0.kind == kind }) { TimelineEditor.addTrack(&before, kind: kind) }
        let originalIndex = try #require(before.tracks.firstIndex { $0.kind == kind })
        before.tracks[originalIndex].isMuted = true
        try TimelineEditor.insert(&before, clip: Clip(source: source, start: 0, duration: 5), on: before.tracks[originalIndex].id)
        sequence.timeline = before
        context.insert(sequence)
        try context.save()

        let added = try payload(try await MCPToolRegistry.invoke(
            name: "sequence_add_track",
            arguments: ["sequence_id": sequence.id.uuidString, "kind": kind.rawValue, "film": document.id.uuidString],
            container: nil
        ))
        let trackIDString = try #require(added["track_id"] as? String)
        let trackID = try #require(UUID(uuidString: trackIDString))
        let after = try await readTimeline(sequenceID: sequence.id, container: document.container)
        let track = try #require(after.tracks.first { $0.id == trackID })
        let expectedName = kind == .video ? "V2" : (kind == .audio ? "A3" : "T2")
        #expect(track.name == expectedName)
        #expect(added["track"] as? String == expectedName)
        #expect(added["kind"] as? String == kind.rawValue)
        #expect(added["sequence_id"] as? String == sequence.id.uuidString)
        #expect(track.clips.isEmpty)
        #expect(!track.isMuted)
        #expect(track.kind == kind)
        let expectedOrder: [String] = switch kind {
        case .video: ["C1", "V1", "V2", "A1", "A2"]
        case .audio: ["C1", "V1", "A1", "A2", "A3"]
        case .overlay, .caption, .zoom: ["T2", "T1", "C1", "V1", "A1", "A2"]
        }
        #expect(after.tracks.map(\.name) == expectedOrder)
        var existing = after
        existing.tracks.removeAll { $0.id == trackID }
        #expect(existing == before)

        let placed = try payload(try await MCPToolRegistry.invoke(
            name: "sequence_add_clip",
            arguments: ["sequence_id": sequence.id.uuidString, "source_id": source.id,
                        "track": trackIDString, "start": 0.0, "duration": 5.0],
            container: document.container
        ))
        let populated = try await readTimeline(sequenceID: sequence.id, container: document.container)
        let newClip = try #require(populated.tracks.first { $0.id == trackID }?.clips.first)
        #expect(newClip.id.uuidString == placed["clip_id"] as? String)
        #expect(newClip.source == source)
        #expect(newClip.start == 0)
        #expect(newClip.duration == 5)
        #expect(populated.tracks.filter { $0.id != trackID } == before.tracks)

        let second = try payload(try await MCPToolRegistry.invoke(
            name: "sequence_add_track",
            arguments: ["sequence_id": sequence.id.uuidString, "kind": kind.rawValue],
            container: document.container
        ))
        #expect(second["track_id"] as? String != trackIDString)
        #expect(second["track"] as? String == (kind == .video ? "V3" : (kind == .audio ? "A4" : "T3")))
    }

    @Test("The reorder tool persists whole tracks and rejects invalid orders")
    func reorderTracks() async throws {
        let schema = ProjectDocument.schema
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let sequence = SequenceProject(name: "Reorder")
        var original = sequence.timeline
        let video = try #require(original.tracks.first { $0.kind == .video })
        try TimelineEditor.insert(&original, clip: Clip(
            source: ClipSource(id: "still", kind: .image, displayName: "Still"), start: 3, duration: 2
        ), on: video.id)
        sequence.timeline = original
        container.mainContext.insert(sequence)
        try container.mainContext.save()
        let tracks = Array(original.tracks.reversed())
        let result = try payload(try await MCPToolRegistry.invoke(
            name: "sequence_reorder_tracks",
            arguments: ["sequence_id": sequence.id.uuidString, "track_ids": tracks.map { $0.id.uuidString }],
            container: container
        ))
        #expect(result["id"] as? String == sequence.id.uuidString)
        let saved = try await readTimeline(sequenceID: sequence.id, container: container)
        #expect(saved.tracks == tracks)
        #expect(saved.id == original.id)
        let ids = tracks.map { $0.id.uuidString }
        for invalid: Any in [NSNull(), "V1", ["invalid"], Array(ids.dropLast()), ids + [UUID().uuidString],
                             [ids[0], ids[0], ids[2], ids[3]]] {
            await #expect(throws: MCPToolError.self) {
                _ = try await MCPToolRegistry.invoke(
                    name: "sequence_reorder_tracks",
                    arguments: ["sequence_id": sequence.id.uuidString, "track_ids": invalid], container: container
                )
            }
            #expect(try await readTimeline(sequenceID: sequence.id, container: container) == saved)
        }
        for policy in AgentWritePolicy.allCases {
            for mode in [AgentThreadMode.conversation, .simpleMode(templateID: "company-intro-video")] {
                #expect(AgentToolPolicy.toolNames(policy: policy, mode: mode).contains("sequence_reorder_tracks"))
                #expect(AgentToolPolicy.allows("sequence_reorder_tracks", policy: policy, mode: mode))
            }
        }
    }

    @Test("A sequence takes several caption tracks, and cues prefer them over the overlay")
    func captionTracks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MCPCaptionTrack-\(UUID())")
        let document = try ProjectDocumentController.shared.createDocument(
            at: root.appendingPathComponent("Captions.rxfilmstudio")
        )
        defer {
            Task {
                await ProjectDocumentController.shared.close(document)
                try? FileManager.default.removeItem(at: root)
            }
        }
        let context = document.container.mainContext
        let captions = CaptionProject(name: "Talk")
        captions.audioDurationMs = 4000
        context.insert(captions)
        let sequence = SequenceProject(name: "Cut")
        context.insert(sequence)
        try context.save()

        // Every sequence starts with C1, so these are the second and third.
        var trackIDs: [String] = []
        for expected in ["C2", "C3"] {
            let added = try payload(try await MCPToolRegistry.invoke(
                name: "sequence_add_track",
                arguments: ["sequence_id": sequence.id.uuidString, "kind": "caption", "film": document.id.uuidString],
                container: nil
            ))
            #expect(added["track"] as? String == expected)
            #expect(added["kind"] as? String == "caption")
            trackIDs.append(try #require(added["track_id"] as? String))
        }
        let layout = try await readTimeline(sequenceID: sequence.id, container: document.container)
        #expect(layout.tracks.map(\.name) == ["C3", "C2", "C1", "V1", "A1", "A2"])

        // Cues land on a caption lane by default, and each lane holds its own.
        for trackID in [nil, trackIDs[0]] {
            var arguments: [String: Any] = ["sequence_id": sequence.id.uuidString,
                                            "source_id": DocumentMediaResolver.sourceID(.caption, captions.projectUUID),
                                            "start": trackID == nil ? 0.0 : 8.0, "duration": 4.0]
            if let trackID { arguments["track"] = trackID }
            _ = try await MCPToolRegistry.invoke(name: "sequence_add_clip", arguments: arguments, container: document.container)
        }
        let filled = try await readTimeline(sequenceID: sequence.id, container: document.container)
        let lanes = filled.tracks.filter { !$0.clips.isEmpty }
        #expect(lanes.count == 2)
        #expect(lanes.allSatisfy { $0.kind == .caption })
        #expect(filled.allClips.allSatisfy { $0.source.kind == .captions })

        // A picture cannot be dropped onto a lane meant for cues.
        await #expect(throws: MCPToolError.self) {
            _ = try await MCPToolRegistry.invoke(
                name: "sequence_add_clip",
                arguments: ["sequence_id": sequence.id.uuidString,
                            "source_id": DocumentMediaResolver.sourceID(.image, UUID()),
                            "track": trackIDs[1], "duration": 2.0],
                container: document.container
            )
        }
    }

    @Test("Invalid kinds and sequence IDs fail without changing a saved timeline")
    func invalidArguments() async throws {
        let schema = Schema([SequenceProject.self])
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let sequence = SequenceProject(name: "Unchanged")
        container.mainContext.insert(sequence)
        try container.mainContext.save()
        let data = sequence.timelineData
        let updatedAt = sequence.updatedAt
        let invalid: [[String: Any]] = [
            ["sequence_id": sequence.id.uuidString],
            ["sequence_id": sequence.id.uuidString, "kind": "subtitle"],
            ["sequence_id": sequence.id.uuidString, "kind": 42],
            ["sequence_id": sequence.id.uuidString, "kind": NSNull()],
            ["kind": "video"],
            ["sequence_id": "invalid", "kind": "audio"],
            ["sequence_id": UUID().uuidString, "kind": "video"],
        ]
        for arguments in invalid {
            await #expect(throws: MCPToolError.self) {
                _ = try await MCPToolRegistry.invoke(name: "sequence_add_track", arguments: arguments, container: container)
            }
        }
        let saved = try #require(ModelContext(container).fetch(FetchDescriptor<SequenceProject>()).first)
        #expect(saved.timelineData == data)
        #expect(saved.updatedAt == updatedAt)
    }
}
