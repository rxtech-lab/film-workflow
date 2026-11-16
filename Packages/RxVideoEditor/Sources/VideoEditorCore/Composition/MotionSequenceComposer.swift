import CoreGraphics
import CoreImage
import Foundation
import VideoEffectsCore

/// A Remotion project nested in a sequence: its `src/` sources and the folder its
/// `staticFile()` calls resolve against.
public struct MotionNestedProject: Sendable, Hashable {
    public var publicDirectory: URL
    /// Paths relative to the project folder, for example `src/Root.tsx`.
    public var files: [String: String]

    public init(publicDirectory: URL, files: [String: String]) {
        self.publicDirectory = publicDirectory
        self.files = files
    }
}

/// Everything the composer needs that comes from outside the timeline: resolved media,
/// probed sizes and durations, reversed audio files and nested Remotion projects.
public struct MotionSequenceSources: Sendable {
    public var media: [String: ResolvedMedia]
    /// Sources that failed to resolve, by source id.
    public var failures: [String: MediaResolverError]
    /// Oriented pixel size of each image or video file.
    public var naturalSizes: [URL: CGSize]
    /// Natural duration of each video file.
    public var durations: [URL: TimeInterval]
    /// Reversed copies of audio, for reversed clips.
    public var reversedAudio: [URL: URL]
    /// Remotion projects by source id.
    public var nested: [String: MotionNestedProject]

    public init(media: [String: ResolvedMedia] = [:], failures: [String: MediaResolverError] = [:],
                naturalSizes: [URL: CGSize] = [:], durations: [URL: TimeInterval] = [:],
                reversedAudio: [URL: URL] = [:], nested: [String: MotionNestedProject] = [:]) {
        self.media = media
        self.failures = failures
        self.naturalSizes = naturalSizes
        self.durations = durations
        self.reversedAudio = reversedAudio
        self.nested = nested
    }
}

public struct MotionSequenceOptions: Sendable, Hashable {
    public enum Audio: Sendable, Hashable {
        /// Every clip is heard, as in an export.
        case all
        /// Only sound inside nested compositions. The preview plays file audio through
        /// AVFoundation and lets MotionSwift add what only it can produce.
        case nestedOnly
        case none
    }

    public var includeCaptions: Bool
    public var audio: Audio
    /// Missing media draws a slate instead of failing, for previews.
    public var allowPlaceholders: Bool
    /// Leaves the picture out; nested compositions still run for their sound.
    public var audioOnly: Bool

    public init(includeCaptions: Bool = true, audio: Audio = .all, allowPlaceholders: Bool = false, audioOnly: Bool = false) {
        self.includeCaptions = includeCaptions
        self.audio = audio
        self.allowPlaceholders = allowPlaceholders
        self.audioOnly = audioOnly
    }

    public static let export = MotionSequenceOptions()
    public static let preview = MotionSequenceOptions(audio: .nestedOnly, allowPlaceholders: true)
}

/// A sequence as a MotionSwift (Remotion-style) film, ready for `MotionSource.files`.
public struct MotionSequenceComposition: Sendable {
    public static let entry = "index.tsx"
    public static let compositionID = "Sequence"

    public let files: [String: String]
    public let width: Int
    public let height: Int
    public let fps: Int
    public let durationInFrames: Int
    /// Draws effects, recordings, captions and slates for elements with a `process` key.
    /// Registered while the composition is in use; see `MotionSequenceProcessor.register()`.
    public let processor: MotionSequenceProcessor
    public let placeholders: [ClipSource]
}

/// Turns a `Timeline` into a MotionSwift film: video and audio files become `OffthreadVideo` and
/// `Audio`, stills `Img`, Remotion clips nested compositions with their own clock and asset folder,
/// and transitions per-frame CSS. Anything that needs Core Image (effects, screen-recording
/// presentation, styled captions, slates) is drawn by the host processor, so the preview and
/// export match the compositor's pictures.
public enum MotionSequenceComposer {
    /// Transitions with a CSS equivalent. Installed (Core Image) transitions have none and are
    /// drawn as a cross dissolve over the same range.
    public static let supportedTransitions: Set<String> = ["rx.cross-dissolve", "rx.fade-color", "rx.directional-wipe"]

    /// What MotionSwift draws differently from the timeline's settings, for a notice in the
    /// viewer. Empty when the picture matches exactly.
    public static func approximations(_ timeline: Timeline) -> [String] {
        var notes: [String] = []
        for transition in timeline.transitions where transition.isEnabled && !supportedTransitions.contains(transition.definitionID) {
            let name = ModifierCatalog.current.transition(transition.definitionID)?.name ?? transition.definitionID
            notes.append("“\(name)” previews as a cross dissolve.")
        }
        for clip in timeline.renderedClips where clip.source.kind == .remotion {
            if clip.effects.contains(where: \.isEnabled) { notes.append("Effects on Remotion clips aren’t drawn."); break }
        }
        return notes
    }

    public static func compose(_ timeline: Timeline, sources: MotionSequenceSources,
                               options: MotionSequenceOptions = .export) throws -> MotionSequenceComposition {
        var builder = Builder(timeline: timeline, sources: sources, options: options)
        return try builder.build()
    }

    // MARK: - Builder

    private struct Builder {
        let timeline: Timeline
        let sources: MotionSequenceSources
        let options: MotionSequenceOptions
        let token = UUID().uuidString.prefix(8).lowercased()
        var jobs: [String: MotionSequenceProcessor.Job] = [:]
        var placeholders: [ClipSource] = []
        var nestedIndex: [String: Int] = [:]
        var nestedOrder: [MotionNestedProject] = []
        var elements: [String] = []

        init(timeline: Timeline, sources: MotionSequenceSources, options: MotionSequenceOptions) {
            self.timeline = timeline
            self.sources = sources
            self.options = options
        }

        var fps: Int { max(1, timeline.fps) }
        func frame(_ seconds: TimeInterval) -> Int { Int((seconds * Double(fps)).rounded()) }

        mutating func build() throws -> MotionSequenceComposition {
            if options.allowPlaceholders { try? timeline.validateModifiers() } else { try timeline.validateModifiers(requireDefinitions: true) }
            let durationFrames = max(1, frame(max(timeline.duration, timeline.frameDuration)))

            // Picture, bottom track first so later elements paint over earlier ones.
            for track in timeline.pictureTracksBackToFront {
                if track.kind.drawsOverPicture, options.audioOnly {
                    for clip in track.renderedClips where clip.source.kind == .remotion { try nested(clip, track: track, hidden: true) }
                    continue
                }
                for clip in track.renderedClips {
                    try picture(clip, track: track)
                }
                if !options.audioOnly { colorFades(on: track) }
            }
            // Sound-only lanes.
            for track in timeline.tracks where track.kind == .audio {
                for clip in track.renderedClips {
                    if clip.source.kind == .remotion { try nested(clip, track: track, hidden: true); continue }
                    try audio(clip, track: track)
                }
            }
            if !options.allowPlaceholders, !placeholders.isEmpty {
                throw CompositionBuildError.unrenderedClips(placeholders)
            }

            var files: [String: String] = [:]
            for (index, project) in nestedOrder.enumerated() {
                for (path, contents) in project.files { files["remotion/\(index)/\(path)"] = contents }
            }
            files[MotionSequenceComposition.entry] = source(durationFrames: durationFrames)
            let processor = MotionSequenceProcessor(token: String(token), jobs: jobs, canvas: timeline.size)
            return MotionSequenceComposition(files: files, width: timeline.width, height: timeline.height, fps: fps,
                                             durationInFrames: durationFrames, processor: processor, placeholders: placeholders)
        }

        // MARK: Clips

        /// The span a clip draws, widened by transitions that join it to a neighbour.
        func renderWindow(_ clip: Clip) -> Range<TimeInterval> {
            var lower = clip.start, upper = clip.end
            for item in timeline.transitions where item.isEnabled && item.attachment.isPair && item.attachment.clipIDs.contains(clip.id) {
                if let range = item.range(in: timeline) { lower = min(lower, range.lowerBound); upper = max(upper, range.upperBound) }
            }
            return lower..<upper
        }

        mutating func picture(_ clip: Clip, track: Track) throws {
            if clip.source.kind == .remotion { try nested(clip, track: track, hidden: options.audioOnly); return }
            if clip.source.kind == .captions {
                guard options.includeCaptions, !options.audioOnly else { return }
                guard case .captions(let cues)? = sources.media[clip.source.id] else { try failure(clip); return }
                let key = job(.captions(clip.captionCues(cues), clip.text ?? .caption))
                let from = frame(clip.start), duration = frame(clip.end) - from
                guard duration > 0 else { return }
                elements.append(#"<Sequence from={\#(from)} durationInFrames={\#(duration)} layout="none"><Processed k=\#(js(key)) offset={\#(Double(from) / Double(fps))} /></Sequence>"#)
                return
            }
            guard track.kind == .video || clip.source.kind == .image else { return }
            guard case .file(let url, _, _)? = sources.media[clip.source.id] else { try failure(clip); return }
            if options.audioOnly {
                if clip.source.kind.hasAudio { try audio(clip, track: track) }
                return
            }
            let processed = clip.effects.contains(where: \.isEnabled) || clip.recording != nil
            let window = clip.isReversed ? clip.range : renderWindow(clip)
            let windowFrom = frame(window.lowerBound), windowDuration = frame(window.upperBound) - windowFrom
            guard windowDuration > 0 else { return }
            let natural = sources.naturalSizes[url] ?? .zero
            let fx = transitionEffects(for: clip, windowFrom: windowFrom)
            let key = processed ? job(.layer(clip: clip, resolved: timeline.resolvedRecordingClip(clip), isImage: clip.source.kind == .image)) : nil
            let placement = "[\(js(clip.transform.fit.rawValue)), \(clip.transform.scale), \(clip.transform.offsetX), \(clip.transform.offsetY)]"
            let style = key == nil ? "{box(place(\(natural.width), \(natural.height), \(placement)))}" : "{FULL}"
            var inner: [String] = []

            if clip.source.kind == .image {
                let process = key.map { " k=\(js($0)) offset={\(Double(windowFrom) / Double(fps))}" } ?? ""
                inner.append(#"<Still src=\#(js(url.path))\#(process) style=\#(style) />"#)
            } else {
                let rate = clip.playbackRate
                let hearsVideo = options.audio == .all && !clip.isReversed && !track.isMuted && clip.volume > 0
                let volume = min(1, max(0, Double(clip.volume)))
                let process = key.map { " process=\(js($0))" } ?? ""
                let sound = hearsVideo ? " volume={\(volume)}" : " muted"
                if clip.isReversed {
                    let start = clip.inPoint * Double(fps), length = clip.sourceRangeDuration * Double(fps)
                    inner.append(#"<OffthreadVideo src=\#(js(url.path)) trimBefore={\#(start)} durationInFrames={\#(length)} playbackRate={\#(rate)} reverse muted\#(process) style=\#(style) />"#)
                } else {
                    // Joined transitions can reach past the media; hold its first or last frame there.
                    let natural = sources.durations[url]
                    let playLower = natural == nil ? window.lowerBound : max(window.lowerBound, clip.start - clip.inPoint / rate)
                    let playUpper = natural.map { min(window.upperBound, clip.start + ($0 - clip.inPoint) / rate) } ?? window.upperBound
                    let playFrom = frame(playLower) - windowFrom, playFrames = frame(playUpper) - frame(playLower)
                    let trim = max(0, clip.inPoint + (playLower - clip.start) * rate) * Double(fps)
                    if playFrom > 0 {
                        inner.append(#"<Sequence from={0} durationInFrames={\#(playFrom)} layout="none"><Freeze frame={0}><OffthreadVideo src=\#(js(url.path)) muted\#(process) style=\#(style) /></Freeze></Sequence>"#)
                    }
                    if playFrames > 0 {
                        inner.append(#"<Sequence from={\#(playFrom)} durationInFrames={\#(playFrames)} layout="none"><OffthreadVideo src=\#(js(url.path)) trimBefore={\#(trim)} playbackRate={\#(rate)}\#(sound)\#(process) style=\#(style) /></Sequence>"#)
                    }
                    let tail = playFrom + max(0, playFrames)
                    if let natural, tail < windowDuration {
                        let last = max(0, natural - 1 / Double(fps)) * Double(fps)
                        inner.append(#"<Sequence from={\#(tail)} durationInFrames={\#(windowDuration - tail)} layout="none"><Freeze frame={0}><OffthreadVideo src=\#(js(url.path)) trimBefore={\#(last)} muted\#(process) style=\#(style) /></Freeze></Sequence>"#)
                    }
                }
                if clip.isReversed { try reversedAudio(clip, url: url, track: track) }
            }
            elements.append(#"<Sequence from={\#(windowFrom)} durationInFrames={\#(windowDuration)} layout="none"><Layer fx={\#(fx)} opacity={\#(Double(clip.opacity))}>\#(inner.joined())</Layer></Sequence>"#)
        }

        mutating func nested(_ clip: Clip, track: Track, hidden: Bool) throws {
            guard let project = sources.nested[clip.source.id] else { try failure(clip); return }
            let index: Int
            if let existing = nestedIndex[clip.source.id] { index = existing } else {
                index = nestedOrder.count
                nestedIndex[clip.source.id] = index
                nestedOrder.append(project)
            }
            let window = clip.isReversed ? clip.range : renderWindow(clip)
            let windowFrom = frame(window.lowerBound), windowDuration = frame(window.upperBound) - windowFrom
            guard windowDuration > 0 else { return }
            let muted = options.audio == .none || track.isMuted || clip.volume <= 0
            let fx = hidden ? "[]" : transitionEffects(for: clip, windowFrom: windowFrom)
            let placement = "[\(js(clip.transform.fit.rawValue)), \(clip.transform.scale), \(clip.transform.offsetX), \(clip.transform.offsetY)]"
            let props = "n={\(index)} t={\(placement)} t0={\(Double(windowFrom) / Double(fps) - clip.start)} ip={\(clip.inPoint)} rate={\(clip.playbackRate)} rev={\(clip.isReversed)} se={\(clip.sourceEnd)} muted={\(muted)}"
            let opacity = hidden ? 0 : Double(clip.opacity)
            elements.append(#"<Sequence from={\#(windowFrom)} durationInFrames={\#(windowDuration)} layout="none"><Layer fx={\#(fx)} opacity={\#(opacity)}><Nested \#(props) /></Layer></Sequence>"#)
        }

        mutating func audio(_ clip: Clip, track: Track) throws {
            guard options.audio == .all, !track.isMuted, clip.volume > 0 else { return }
            guard case .file(let url, _, _)? = sources.media[clip.source.id] else {
                if case .unrendered? = sources.failures[clip.source.id] { placeholders.append(clip.source); return }
                if let error = sources.failures[clip.source.id], !options.allowPlaceholders { throw error }
                return
            }
            if clip.isReversed { try reversedAudio(clip, url: url, track: track); return }
            let from = frame(clip.start), duration = frame(clip.end) - from
            guard duration > 0 else { return }
            let volume = min(1, max(0, Double(clip.volume)))
            elements.append(#"<Sequence from={\#(from)} durationInFrames={\#(duration)} layout="none"><Audio src=\#(js(url.path)) trimBefore={\#(clip.inPoint * Double(fps))} playbackRate={\#(clip.playbackRate)} volume={\#(volume)} /></Sequence>"#)
        }

        /// Reversed sound plays a reversed copy forwards, from the mirror of the clip's range.
        mutating func reversedAudio(_ clip: Clip, url: URL, track: Track) throws {
            guard options.audio == .all, !track.isMuted, clip.volume > 0, let reversed = sources.reversedAudio[url] else { return }
            let natural = sources.durations[url] ?? clip.sourceDuration ?? clip.sourceEnd
            let start = max(0, natural - clip.sourceEnd)
            let from = frame(clip.start), duration = frame(clip.end) - from
            guard duration > 0 else { return }
            let volume = min(1, max(0, Double(clip.volume)))
            elements.append(#"<Sequence from={\#(from)} durationInFrames={\#(duration)} layout="none"><Audio src=\#(js(reversed.path)) trimBefore={\#(start * Double(fps))} playbackRate={\#(clip.playbackRate)} volume={\#(volume)} /></Sequence>"#)
        }

        mutating func failure(_ clip: Clip) throws {
            let error = sources.failures[clip.source.id] ?? .missing(clip.source)
            guard options.allowPlaceholders else {
                if case .unrendered = error { placeholders.append(clip.source); return }
                throw error
            }
            placeholders.append(clip.source)
            guard !options.audioOnly else { return }
            let from = frame(clip.start), duration = frame(clip.end) - from
            guard duration > 0 else { return }
            let key = job(.placeholder(clip.source.displayName))
            elements.append(#"<Sequence from={\#(from)} durationInFrames={\#(duration)} layout="none"><Processed k=\#(js(key)) offset={0} /></Sequence>"#)
        }

        mutating func job(_ job: MotionSequenceProcessor.Job) -> String {
            let key = "\(token):\(jobs.count)"
            jobs[key] = job
            return key
        }

        // MARK: Transitions

        /// Per-frame styles for the transitions touching `clip`, in frames local to its window.
        func transitionEffects(for clip: Clip, windowFrom: Int) -> String {
            var items: [String] = []
            for transition in timeline.transitions where transition.isEnabled && transition.attachment.clipIDs.contains(clip.id) {
                guard let range = transition.range(in: timeline) else { continue }
                let role: String
                switch transition.attachment {
                case .start: role = "edgeIn"
                case .end: role = "edgeOut"
                case .between(let outgoing, _): role = outgoing == clip.id ? "out" : "in"
                }
                let kind: String
                switch transition.definitionID {
                case "rx.cross-dissolve": kind = "dissolve"
                case "rx.fade-color": kind = "fade"
                case "rx.directional-wipe": kind = "wipe"
                default: kind = "dissolve"
                }
                let a = frame(range.lowerBound) - windowFrom, b = frame(range.upperBound) - windowFrom
                let curve = transition.parameters.string("curve") == "Ease In Out"
                let direction = transition.parameters.string("direction", default: "Right")
                items.append("{k: \(js(kind)), role: \(js(role)), a: \(a), b: \(b), ease: \(curve), dir: \(js(direction))}")
            }
            return "[" + items.joined(separator: ", ") + "]"
        }

        /// Fade through Color draws its color above the clips it joins.
        mutating func colorFades(on track: Track) {
            for transition in timeline.transitions where transition.isEnabled && transition.definitionID == "rx.fade-color"
                && transition.attachment.clipIDs.contains(where: { id in track.renderedClips.contains { $0.id == id } }) {
                guard let range = transition.range(in: timeline) else { continue }
                let from = frame(range.lowerBound), duration = frame(range.upperBound) - from
                guard duration > 0 else { continue }
                let role: String
                switch transition.attachment {
                case .start: role = "edgeIn"
                case .end: role = "edgeOut"
                case .between: role = "between"
                }
                let color = transition.parameters.string("color", default: "#000000")
                elements.append(#"<Sequence from={\#(from)} durationInFrames={\#(duration)} layout="none"><ColorFade role=\#(js(role)) length={\#(duration)} color=\#(js(color)) /></Sequence>"#)
            }
        }

        // MARK: Source

        func source(durationFrames: Int) -> String {
            var imports = ""
            var table: [String] = []
            for (index, project) in nestedOrder.enumerated() {
                let root = project.files.keys.contains("src/Root.tsx") ? "./remotion/\(index)/src/Root" : nil
                let composition = project.files.keys.contains("src/Composition.tsx") ? "./remotion/\(index)/src/Composition" : nil
                if let root { imports += "import * as N\(index)Root from \(js(root));\n" }
                if let composition { imports += "import * as N\(index)Comp from \(js(composition));\n" }
                table.append("{root: \(root == nil ? "{}" : "N\(index)Root"), comp: \(composition == nil ? "{}" : "N\(index)Comp"), dir: \(js(project.publicDirectory.standardizedFileURL.path))}")
            }
            return """
            import React from 'react';
            import {AbsoluteFill, Audio, Composition, Freeze, Img, OffthreadVideo, Sequence, StaticFileRoot, registerRoot, useCurrentFrame, useVideoConfig, __Config, __Frame, __MediaEnabled} from 'remotion';
            \(imports)
            // Generated by Film Studio from a sequence timeline. Edit the timeline, not this file.
            const W = \(timeline.width), H = \(timeline.height), FPS = \(fps);
            const BLANK = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
            const FULL = {position: 'absolute', left: 0, top: 0, width: W, height: H, objectFit: 'fill'};
            const box = r => ({position: 'absolute', left: r[0], top: r[1], width: r[2], height: r[3], objectFit: 'fill'});
            // PreviewGeometry.placement, in CSS (top-left) coordinates.
            function place(sw, sh, t) {
              const [fit, scale, ox, oy] = t;
              if (!(sw > 0 && sh > 0)) return [0, 0, W, H];
              const x = W / sw, y = H / sh;
              let w, h;
              if (fit === 'fill') { const k = Math.max(x, y); w = sw * k * scale; h = sh * k * scale; }
              else if (fit === 'stretch') { w = W * scale; h = H * scale; }
              else { const k = Math.min(x, y); w = sw * k * scale; h = sh * k * scale; }
              const left = (W - w) / 2 + ox * W, bottom = (H - h) / 2 + oy * H;
              return [left, H - bottom - h, w, h];
            }
            const clamp01 = v => Math.max(0, Math.min(1, v));
            function wipeRect(dir, t) {
              if (dir === 'Left') return [1 - t, 0, 1, 1];
              if (dir === 'Up') return [0, 1 - t, 1, 1];
              if (dir === 'Down') return [0, 0, 1, t];
              return [0, 0, t, 1];
            }
            function complement(dir, t) {
              if (dir === 'Left') return [0, 0, 1 - t, 1];
              if (dir === 'Up') return [0, 0, 1, 1 - t];
              if (dir === 'Down') return [0, t, 1, 1];
              return [t, 0, 1, 1];
            }
            const polygon = ([x0, y0, x1, y1]) => `polygon(${x0 * 100}% ${y0 * 100}%, ${x1 * 100}% ${y0 * 100}%, ${x1 * 100}% ${y1 * 100}%, ${x0 * 100}% ${y1 * 100}%)`;
            function layerStyle(f, fx, opacity) {
              let alpha = opacity, clip = null;
              for (const e of fx) {
                if (f < e.a || f >= e.b) continue;
                let t = clamp01((f - e.a) / Math.max(1, e.b - e.a));
                if (e.k === 'dissolve') {
                  if (e.ease) t = t * t * (3 - 2 * t);
                  if (e.role === 'in' || e.role === 'edgeIn') alpha *= t;
                  else if (e.role === 'edgeOut') alpha *= 1 - t;
                } else if (e.k === 'fade') {
                  if (e.role === 'out' && t >= 0.5) alpha = 0;
                  if (e.role === 'in' && t < 0.5) alpha = 0;
                } else if (e.k === 'wipe') {
                  const reveal = e.role === 'in' || e.role === 'edgeIn';
                  if (e.role === 'out') continue;
                  if (reveal) { if (t <= 0) alpha = 0; else if (t < 1) clip = polygon(wipeRect(e.dir, t)); }
                  else { if (t >= 1) alpha = 0; else if (t > 0) clip = polygon(complement(e.dir, t)); }
                }
              }
              const style = {};
              if (alpha < 1) style.opacity = Math.max(0, alpha);
              if (clip) style.clipPath = clip;
              return style;
            }
            const Layer = ({fx, opacity, children}) => {
              const f = useCurrentFrame();
              return <AbsoluteFill style={layerStyle(f, fx, opacity)}>{children}</AbsoluteFill>;
            };
            const ColorFade = ({role, length, color}) => {
              const f = useCurrentFrame();
              const t = clamp01(f / Math.max(1, length));
              const alpha = role === 'edgeIn' ? 1 - t : role === 'edgeOut' ? t : (t < 0.5 ? t * 2 : 2 - t * 2);
              return <AbsoluteFill style={{backgroundColor: color, opacity: clamp01(alpha)}} />;
            };
            const Processed = ({k, offset}) => {
              const f = useCurrentFrame();
              return <Img src={BLANK} process={k} processTime={offset + f / FPS} style={FULL} />;
            };
            const Still = ({src, k, offset, style}) => {
              const f = useCurrentFrame();
              return k ? <Img src={src} process={k} processTime={offset + f / FPS} style={style} /> : <Img src={src} style={style} />;
            };
            const NESTED = [\(table.joined(separator: ", "))];
            function collect(node, out, depth) {
              if (!node || depth > 24) return;
              if (Array.isArray(node)) { for (const child of node) collect(child, out, depth + 1); return; }
              if (typeof node !== 'object') return;
              const props = node.props || {};
              if (typeof props.component === 'function' && props.width > 0 && props.height > 0) out.push(props);
              collect(props.children, out, depth + 1);
            }
            function resolveNested(entry) {
              if (entry.resolved) return entry.resolved;
              const found = [];
              const root = entry.root.RemotionRoot || entry.root.default || Object.values(entry.root).find(v => typeof v === 'function');
              try { if (root) collect(root({}), found, 0); } catch (error) {}
              let props = found.find(p => p.id === 'Main') || found[0];
              if (!props) {
                const c = entry.comp;
                const component = c.MyComposition || c.default || Object.values(c).find(v => typeof v === 'function');
                if (!component) throw Error('A nested Remotion project registers no composition');
                props = {id: 'Main', component, width: c.COMPOSITION_WIDTH || W, height: c.COMPOSITION_HEIGHT || H,
                  fps: c.COMPOSITION_FPS || FPS, durationInFrames: c.COMPOSITION_DURATION_IN_FRAMES || 1};
              }
              entry.resolved = {id: props.id || 'Main', component: props.component, width: props.width, height: props.height,
                fps: props.fps || 30, durationInFrames: Math.max(1, props.durationInFrames || 1), defaultProps: props.defaultProps || {}};
              return entry.resolved;
            }
            const Nested = ({n, t, t0, ip, rate, rev, se, muted}) => {
              const f = useCurrentFrame();
              const parent = useVideoConfig();
              const entry = NESTED[n];
              const c = resolveNested(entry);
              const tau = t0 + f / FPS;
              const source = rev ? se - tau * rate : ip + tau * rate;
              const local = Math.max(0, Math.min(c.durationInFrames - 1, Math.floor(source * c.fps + 1e-6)));
              const r = place(c.width, c.height, t);
              const Component = c.component;
              let content = <__Config.Provider value={{...parent, id: c.id, width: c.width, height: c.height, fps: c.fps, durationInFrames: c.durationInFrames}}>
                <__Frame.Provider value={local}><StaticFileRoot root={entry.dir}><Component {...c.defaultProps} /></StaticFileRoot></__Frame.Provider>
              </__Config.Provider>;
              if (muted) content = <__MediaEnabled.Provider value={false}>{content}</__MediaEnabled.Provider>;
              return <div style={{position: 'absolute', left: r[0], top: r[1], width: r[2], height: r[3], overflow: 'hidden'}}>
                <div style={{position: 'absolute', left: 0, top: 0, width: c.width, height: c.height, transform: `scale(${r[2] / c.width}, ${r[3] / c.height})`, transformOrigin: 'left top'}}>{content}</div>
              </div>;
            };
            const Film = () => <AbsoluteFill style={{backgroundColor: \(js(timeline.backgroundHex))}}>
            \(elements.map { "  " + $0 }.joined(separator: "\n"))
            </AbsoluteFill>;
            registerRoot(() => <Composition id=\(js(MotionSequenceComposition.compositionID)) component={Film} width={W} height={H} fps={FPS} durationInFrames={\(durationFrames)} />);

            """
        }
    }

    /// A JavaScript string literal.
    static func js(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = (try? encoder.encode(string)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private func js(_ string: String) -> String { MotionSequenceComposer.js(string) }

/// Draws the pictures MotionSwift cannot: Core Image effects, screen-recording presentation,
/// styled captions and slates, through the same code the AVFoundation compositor uses.
public final class MotionSequenceProcessor: @unchecked Sendable {
    public enum Job: Sendable {
        /// A video or still with effects and/or a recording presentation. The element covers the
        /// frame; the processor places the source in it.
        case layer(clip: Clip, resolved: Clip, isImage: Bool)
        case captions([TextCue], TextStyle)
        case placeholder(String)
    }

    public let token: String
    let jobs: [String: Job]
    let canvas: CGSize

    init(token: String, jobs: [String: Job], canvas: CGSize) {
        self.token = token
        self.jobs = jobs
        self.canvas = canvas
    }

    public var isEmpty: Bool { jobs.isEmpty }

    private static let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: [.cacheIntermediates: false]) }
        return CIContext(options: [.cacheIntermediates: false])
    }()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Registry

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered: [String: MotionSequenceProcessor] = [:]

    /// Makes this composition's keys resolvable by `process(_:key:time:pixelWidth:pixelHeight:)`.
    public func register() { Self.lock.withLock { Self.registered[token] = self } }
    public func unregister() { Self.lock.withLock { _ = Self.registered.removeValue(forKey: token) } }

    /// Entry point for MotionSwift's `MediaProcessing.processor`. Called on render workers.
    public static func process(_ image: CGImage, key: String, time: Double, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard let token = key.split(separator: ":").first.map(String.init),
              let processor = lock.withLock({ registered[token] }) else { return nil }
        return processor.process(image, key: key, time: time, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    // MARK: Drawing

    /// `time` is source seconds for video, timeline seconds for stills and overlays.
    public func process(_ image: CGImage, key: String, time: Double, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard let job = jobs[key] else { return nil }
        let frame = CGRect(origin: .zero, size: canvas)
        let output: CIImage?
        switch job {
        case .layer(let clip, let resolved, let isImage):
            var source = CIImage(cgImage: image)
            source = ModifierCatalog.current.apply(clip.effects, to: source)
            var placed: CIImage? = TimelineVideoCompositor.place(source, in: frame, transform: clip.transform, opacity: 1)
            if resolved.recording != nil {
                let timelineTime = isImage ? time : Self.timelineTime(ofSource: time, in: clip)
                var presented = resolved
                presented.opacity = 1
                placed = RecordingRenderer.render(placed, clip: presented, time: timelineTime, size: canvas)
            }
            output = placed
        case .captions(let cues, let style):
            let text = cues.filter { $0.start <= time && time < $0.end }.map(\.text).joined(separator: "\n")
            output = text.isEmpty ? nil : TextRenderer.shared.image(for: text, style: style, frameSize: canvas)
        case .placeholder(let name):
            output = TimelineVideoCompositor.placeholder(named: name, in: frame)
        }
        guard let output else { return nil }
        let pixels = CGSize(width: max(1, pixelWidth), height: max(1, pixelHeight))
        let scaled = output.cropped(to: frame)
            .transformed(by: CGAffineTransform(scaleX: pixels.width / max(1, canvas.width), y: pixels.height / max(1, canvas.height)))
        return Self.context.createCGImage(scaled, from: CGRect(origin: .zero, size: pixels), format: .RGBA8, colorSpace: Self.colorSpace)
    }

    /// Inverts `Clip.sourceTime(at:)`.
    static func timelineTime(ofSource source: Double, in clip: Clip) -> Double {
        let elapsed = clip.isReversed ? clip.sourceEnd - source : source - clip.inPoint
        return clip.start + elapsed / clip.playbackRate
    }
}
