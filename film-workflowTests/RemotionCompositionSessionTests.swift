import Foundation
import MotionCore
import MotionEditor
import MotionPortable
import MotionSwiftUI
import SwiftData
import Testing
import VideoEditorCore
@testable import film_workflow

/// Double-clicking a Remotion clip opens its composition on the app's own timeline: each
/// element is a lane, and moving or trimming a lane rewrites the element's timing in the TSX.
@Suite("Remotion composition timeline", .serialized) @MainActor
struct RemotionCompositionSessionTests {
    private let source = """
    import React from 'react';
    import {AbsoluteFill, Sequence} from 'remotion';
    export const COMPOSITION_WIDTH = 320;
    export const COMPOSITION_HEIGHT = 180;
    export const COMPOSITION_FPS = 30;
    export const COMPOSITION_DURATION_IN_FRAMES = 90;
    export const MyComposition = () => (
      <AbsoluteFill style={{backgroundColor: '#000000'}}>
        <Sequence from={0} durationInFrames={30}>
          {/* 🎬 */}<div data-ms-label="Opening title" style={{position: 'absolute', left: 10, top: 10, width: 100, height: 40, color: 'white', fontSize: 20}}>Title</div>
        </Sequence>
      </AbsoluteFill>
    );
    """

    private let rich3DAndHelperSource = """
    import React from 'react';
    import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
    import {ThreeCanvas} from '@remotion/three';
    export const COMPOSITION_WIDTH = 1920;
    export const COMPOSITION_HEIGHT = 1080;
    export const COMPOSITION_FPS = 30;
    export const COMPOSITION_DURATION_IN_FRAMES = 300;

    const Title: React.FC<{s: number; from: number; to: number; size?: number; top?: number; children: React.ReactNode}> = ({
      s, from, to, size = 92, top = 710, children,
    }) => {
      if (s < from || s > to) return null;
      return (
        <div style={{position: 'absolute', left: 0, right: 0, top, fontSize: size, color: '#f5f5f7', textAlign: 'center'}}>
          {children}
        </div>
      );
    };

    const Rail: React.FC<{t: number}> = ({t}) => (
      <mesh position={[t * 0.1, 0, 0]}>
        <boxGeometry args={[2, 0.2, 0.2]} />
        <meshStandardMaterial color="#d4d4d8" />
      </mesh>
    );

    export const MyComposition: React.FC = () => {
      const f = useCurrentFrame();
      const {fps} = useVideoConfig();
      const t = f / fps;
      return (
        <AbsoluteFill style={{backgroundColor: '#07070b'}}>
          <Title s={t} from={1.0} to={6.0} size={92} top={710}>Until you hit render.</Title>
          <ThreeCanvas width={1920} height={1080}>
            <ambientLight intensity={0.8} />
            <Rail t={t} />
          </ThreeCanvas>
          <div style={{position: 'absolute', inset: 0, background: 'radial-gradient(ellipse at center, transparent 58%, rgba(0,0,0,0.6) 100%)'}} />
        </AbsoluteFill>
      );
    };
    """

    @Test("Elements become lanes and lane edits write element timing")
    func elementsBecomeEditableLanes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompositionSession-" + UUID().uuidString).appendingPathExtension("rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let context = document.container.mainContext
        let project = RemotionProject(name: "Title card")
        project.compositionSource = source
        context.insert(project)
        try RemotionCodeBuilder.writeComposition(project: project, source: source)
        try context.save()

        let session = RemotionCompositionSession(project: project, clipID: UUID())
        await session.open()
        #expect(session.setupError == nil)
        let model = try #require(session.model)
        #expect(session.timeline.width == 320 && session.timeline.fps == 30)
        #expect(!session.timeline.tracks.isEmpty)
        let lane = try #require(session.timeline.tracks.first { $0.name == "Opening title · Title" })
        #expect(session.elementTypesByTrackID[lane.id] == "div")
        let clip = try #require(lane.clips.first)
        #expect(clip.source.capabilities.contains(.drag))

        // Select from the timeline: the element becomes MotionSwift's selection.
        session.selectedClipIDs = [clip.id]
        #expect(model.selection != nil)

        // Trim the span to half a second; the composition source changes on disk. (Moving it past
        // its enclosing Sequence would be refused by MotionSwift.)
        var edited = session.timeline
        try TimelineEditor.update(&edited, clipID: clip.id) { $0.duration = 0.5 }
        let before = try String(contentsOf: project.compositionSourceURL, encoding: .utf8)
        session.apply(edited)
        for _ in 0..<200 {
            if (try? String(contentsOf: project.compositionSourceURL, encoding: .utf8)) != before { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let after = try String(contentsOf: project.compositionSourceURL, encoding: .utf8)
        #expect(after != before)
        session.syncFromDisk(context: context)
        #expect(project.compositionSource == after)
        // The model re-reads its tracks after the write; the lane follows.
        for _ in 0..<200 {
            session.rebuildTimeline()
            if let span = session.timeline.allClips.first(where: { $0.id == clip.id }), abs(span.duration - 0.5) < 0.05 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let moved = try #require(session.timeline.allClips.first { $0.id == clip.id })
        #expect(abs(moved.duration - 0.5) < 0.05)
        await document.close()
    }

    @Test("3D and helper-component compositions detect elements immediately, scrub smoothly on GPU, and edit props and text")
    func helperComponentsDetectImmediatelyScrubAndEdit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Composition3D-" + UUID().uuidString).appendingPathExtension("rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let context = document.container.mainContext
        let project = RemotionProject(name: "BG 5 — Waiting on the render (3D)")
        project.compositionWidth = 1920
        project.compositionHeight = 1080
        project.compositionFps = 30
        project.durationSeconds = 10
        project.compositionSource = rich3DAndHelperSource
        context.insert(project)
        try RemotionCodeBuilder.writeComposition(project: project, source: rich3DAndHelperSource)
        try context.save()

        let start = ContinuousClock.now
        let session = RemotionCompositionSession(project: project, clipID: UUID())
        await session.open()
        #expect(session.setupError == nil)
        let model = try #require(session.model)

        // Tracks are detected immediately on open without needing to play to t = 1.0s first.
        #expect(session.timeline.tracks.contains { $0.name == "Title · Until you hit render." })
        #expect(session.timeline.tracks.contains { $0.name == "mesh" })

        // First GPU frame arrives quickly (well under a second, vs 50s on CPU@2x).
        for _ in 0..<150 where model.player.displayedFrame == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.player.displayedFrame?.frame == 0)
        #expect(ContinuousClock.now - start < .seconds(5))

        // Scrubbing the timeline playhead renders the target frame, and skimming restores the resting playhead.
        session.playhead = 2.0
        for _ in 0..<150 where model.player.displayedFrame?.frame != 60 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.player.displayedFrame?.frame == 60)

        session.skim(to: 4.0)
        #expect(abs(session.playhead - 2.0) < 0.001)
        #expect(model.player.currentFrame == 120)
        session.endSkim()
        #expect(model.player.currentFrame == 60)

        // Select the Title element and edit both its text and custom prop (`size`).
        let titleTrack = try #require(model.timelineTracks.first { $0.label == "Title" })
        session.selectElement(titleTrack.src)
        for _ in 0..<150 where model.styles == nil || model.textContent == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.canEditText)
        #expect(model.selectedTextValue == "Until you hit render.")
        let original = try String(contentsOf: project.compositionSourceURL, encoding: .utf8)
        #expect(await model.setText("Ready in real time.", source: titleTrack.src, expectedSource: original))
        await model.setStyle("size", .number(108))
        session.syncFromDisk(context: context)
        #expect(project.compositionSource.contains("Ready in real time."))
        #expect(project.compositionSource.contains("size={108}"))
        await document.close()
    }

    @Test("Clicking another sequence in the media panel jumps out of the composition")
    func librarySequenceJumpsOut() {
        let state = EditorWindowState(defaults: UserDefaults(suiteName: "CompositionJump-\(UUID())")!)
        let project = RemotionProject(name: "Title card")
        let first = UUID(), other = UUID()
        state.select(LibraryItemID(kind: .sequence, id: first))
        state.openComposition(project, clipID: UUID())
        #expect(state.composition != nil)
        state.select(LibraryItemID(kind: .sequence, id: other))
        #expect(state.composition == nil)
        #expect(state.currentSequenceID == other)
        #expect(state.viewerSelection == LibraryItemID(kind: .sequence, id: other))
    }

    @Test("Double-clicking a Remotion item in the media panel opens its timeline")
    func libraryDoubleClickOpens() {
        let state = EditorWindowState(defaults: UserDefaults(suiteName: "CompositionOpen-\(UUID())")!)
        let project = RemotionProject(name: "Title card")
        // The first click selects, the second opens; selecting must not undo the open.
        state.select(LibraryItemID(kind: .remotion, id: project.id))
        state.openComposition(project)
        #expect(state.composition?.projectID == project.id)
        #expect(state.composition?.clipID == nil)
    }
}
