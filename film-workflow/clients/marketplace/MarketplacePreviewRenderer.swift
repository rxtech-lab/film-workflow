import AppKit
import AVFoundation
import CryptoKit
import Foundation
import SwiftData
import VideoEditorCore
import VideoEffectsCore

/// Uses the production timeline exporter, with a resolver containing only preview assets.
@MainActor enum MarketplacePreviewRenderer {
    private static var temporaryUsers: [String: Int] = [:]
    struct Output { var video: URL; var cover: URL }
    nonisolated struct Resolver: MediaResolver {
        var files: [String: URL]
        func resolve(_ source: ClipSource) async throws -> ResolvedMedia {
            guard let file = files[source.id] else { throw MediaResolverError.missing(source) }
            return .file(file, naturalDuration: nil, naturalSize: nil)
        }
        func thumbnail(for source: ClipSource, at time: TimeInterval) async -> CGImage? { nil }
    }
    static func render(item: MarketplaceAuthoringItem, start: Double, duration: Double, demoPath: String?, service: MarketplaceAuthoringService? = nil, contentFile: ((MarketplaceAuthoringItem) async throws -> URL)? = nil, mockAsset: ((String, String) async throws -> URL)? = nil, progress: @escaping @MainActor (Double) -> Void) async throws -> Output {
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0 else { throw MarketplaceAuthoringError.invalid("Choose a positive preview length and a valid start time.") }
        let service = service ?? MarketplaceAuthoringService.shared
        func loadContent(_ value: MarketplaceAuthoringItem) async throws -> URL {
            if let contentFile { return try await contentFile(value) }
            return try await service.localContent(value)
        }
        func makeMock(name: String, prompt: String) async throws -> URL {
            if let mockAsset { return try await mockAsset(name, prompt) }
            return try await mockImage(itemId: item.id, name: name, prompt: prompt)
        }
        let directory = try service.directory(for: item.id)
        let signature = (item.contentRevision ?? item.contentText ?? item.item.contentFilename ?? "") + "\(item.item.contentSizeBytes ?? 0):\(start):\(duration):\(demoPath ?? "")"
        let key = SHA256.hash(data: Data(signature.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let video = directory.appendingPathComponent("preview-\(key).mp4")
        let cover = directory.appendingPathComponent("cover-\(key).png")
        if FileManager.default.fileExists(atPath: video.path), FileManager.default.fileExists(atPath: cover.path) { return Output(video: video, cover: cover) }
        let limit = min(duration, 15)
        var timeline = Timeline(width: 1280, height: 720, fps: 30)
        var files: [String: URL] = [:]
        var visualClips: [Clip] = []
        var temporaryDefinitions: Set<String> = []
        defer {
            if !temporaryDefinitions.isEmpty {
                let installed = ModifierCatalog.installed
                let released = Set(temporaryDefinitions.filter { id in
                    temporaryUsers[id, default: 1] -= 1
                    if temporaryUsers[id] == 0 { temporaryUsers[id] = nil; return true }
                    return false
                })
                ModifierCatalog.setInstalled(.init(effects: installed.effects.filter { !released.contains($0.id) }, transitions: installed.transitions.filter { !released.contains($0.id) }, previewURLs: installed.previewURLs))
            }
        }
        func source(_ file: URL, kind: SourceKind, name: String) -> ClipSource {
            let id = UUID().uuidString; files[id] = file
            return ClipSource(id: id, kind: kind, displayName: name)
        }
        switch item.item.kind {
        case .projectTemplate:
            guard let template = item.template else { throw MarketplaceAuthoringError.invalid("Save a template definition first.") }
            try template.validate(publishing: true)
            timeline.width = template.width; timeline.height = template.height; timeline.fps = template.fps
            var time: Double = 0
            let previewShots = Array(template.shots.prefix(max(1, Int(limit * Double(template.fps)))))
            let total = previewShots.reduce(0) { $0 + $1.durationSeconds }
            let ratio = min(1, limit / max(total, 0.01))
            for (index, shot) in previewShots.enumerated() {
                if time + 1 / Double(template.fps) > limit + 0.000001 { break }
                // No source-film media enters this resolver. All pictures are generated mock scenes.
                let mock = try await makeMock(name: "\(key)-shot-\(index)", prompt: "Create a fictional mock image for a video template preview. \(template.videoStyle). Shot: \(shot.instructions). Do not use any real project footage. No text or watermark.")
                let clip = Clip(source: source(mock, kind: .image, name: shot.title), start: time, duration: min(limit - time, max(1 / Double(template.fps), shot.durationSeconds * ratio)))
                visualClips.append(clip); time += clip.duration
                progress(Double(index + 1) / Double(max(1, template.shots.count)) * 0.4)
            }
            // Resolve published modifier dependencies for the demo without copying any source footage.
            for dependency in template.marketplaceItems {
                let entry = try await service.get(dependency.itemId)
                if [.transition, .effect].contains(entry.item.kind) {
                    let local = try await loadContent(entry)
                    let descriptor = try InstalledModifierLoader.descriptor(at: local, expecting: entry.item.kind)
                    if temporaryUsers[descriptor.id] != nil || (ModifierCatalog.current.effect(descriptor.id) == nil && ModifierCatalog.current.transition(descriptor.id) == nil) {
                        if temporaryDefinitions.insert(descriptor.id).inserted {
                            if temporaryUsers[descriptor.id] == nil { register(descriptor) }
                            temporaryUsers[descriptor.id, default: 0] += 1
                        }
                    }
                } else if [.audio, .soundEffect].contains(entry.item.kind) {
                    let local = try await loadContent(entry)
                    let seconds = try await AVURLAsset(url: local).load(.duration).seconds
                    let trackIndex = timeline.tracks.firstIndex { $0.kind == .audio }!
                    if timeline.tracks[trackIndex].clips.isEmpty {
                        timeline.tracks[trackIndex].clips = [Clip(source: source(local, kind: .audio, name: entry.item.title), start: 0, duration: min(seconds, time))]
                    }
                }
            }
            for index in visualClips.indices {
                visualClips[index].effects = try template.shots[index].effects.map { modifier in
                    guard ModifierCatalog.current.effect(modifier.modifierId) != nil else { throw MarketplaceAuthoringError.invalid("An effect required by the template is unavailable: \(modifier.modifierId)") }
                    return EffectInstance(definitionID: modifier.modifierId, parameters: modifier.parameters)
                }
                if index + 1 < visualClips.count, let modifier = template.shots[index].transition {
                    guard ModifierCatalog.current.transition(modifier.modifierId) != nil else { throw MarketplaceAuthoringError.invalid("A transition required by the template is unavailable: \(modifier.modifierId)") }
                    timeline.transitions.append(.init(definitionID: modifier.modifierId, parameters: modifier.parameters,
                        attachment: .between(outgoing: visualClips[index].id, incoming: visualClips[index + 1].id),
                        duration: min(modifier.durationSeconds ?? 0.5, min(visualClips[index].duration, visualClips[index + 1].duration) / 2)))
                }
            }
        case .footage, .remotionPrompt:
            let local: URL
            if item.item.kind == .remotionPrompt {
                guard let demoPath else { throw MarketplaceAuthoringError.invalid("Render this prompt in its authoring workspace using mock assets, then supply the rendered demo as demo_path.") }
                local = URL(fileURLWithPath: demoPath).standardizedFileURL
                guard local.path.hasPrefix(directory.standardizedFileURL.path + "/") else { throw MarketplaceAuthoringError.invalid("Use a mock demo rendered inside this item's authoring workspace.") }
            } else { local = try await loadContent(item) }
            let asset = AVURLAsset(url: local)
            let seconds = try await asset.load(.duration).seconds
            guard seconds.isFinite, start < seconds else { throw MarketplaceAuthoringError.invalid("The preview starts after the clip ends.") }
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
                let oriented = size.applying(transform)
                timeline.width = Int(abs(oriented.width)); timeline.height = Int(abs(oriented.height))
            }
            visualClips = [Clip(source: source(local, kind: .video, name: item.item.title), start: 0, duration: min(limit, seconds - start), inPoint: start)]
        case .audio, .soundEffect:
            let local = try await loadContent(item)
            let seconds = try await AVURLAsset(url: local).load(.duration).seconds
            guard seconds.isFinite, start < seconds else { throw MarketplaceAuthoringError.invalid("The preview starts after the audio ends.") }
            let length = min(limit, seconds - start)
            let artwork: URL
            if let url = item.item.previewImageUrl {
                artwork = directory.appendingPathComponent("audio-cover-\(key).png")
                if !FileManager.default.fileExists(atPath: artwork.path) { try await MarketplaceDownloader.download(from: url, to: artwork) }
            } else { artwork = try await makeMock(name: "audio-cover-\(key)", prompt: "Album cover artwork for \(item.item.title). \(item.item.description). No text.") }
            visualClips = [Clip(source: source(artwork, kind: .image, name: item.item.title), start: 0, duration: length)]
            let index = timeline.tracks.firstIndex { $0.kind == .audio }!
            timeline.tracks[index].clips = [Clip(source: source(local, kind: .audio, name: item.item.title), start: 0, duration: length, inPoint: start)]
        case .font:
            let local = try await loadContent(item)
            guard MarketplaceFonts.register(local), let name = MarketplaceFonts.postScriptName(of: local), let font = NSFont(name: name, size: 62) else { throw MarketplaceAuthoringError.invalid("This font could not be loaded.") }
            let specimen = directory.appendingPathComponent("specimen-\(key).png")
            try drawSpecimen(title: item.item.title, font: font, to: specimen)
            visualClips = [Clip(source: source(specimen, kind: .image, name: item.item.title), start: 0, duration: min(limit, 6))]
        case .effect, .transition:
            let local = try await loadContent(item)
            var descriptor = try InstalledModifierLoader.descriptor(at: local, expecting: item.item.kind)
            descriptor.id = "preview.\(item.id)"
            register(descriptor); temporaryDefinitions.insert(descriptor.id); temporaryUsers[descriptor.id, default: 0] += 1
            let first = try await makeMock(name: "demo-a", prompt: "Fictional cinematic landscape with warm mountains and a blue lake, high contrast, no text.")
            let second = try await makeMock(name: "demo-b", prompt: "Fictional cinematic city at night with bright neon, no text.")
            let length = min(limit, 6)
            visualClips = [Clip(source: source(first, kind: .image, name: "Before"), start: 0, duration: length / 2), Clip(source: source(second, kind: .image, name: "After"), start: length / 2, duration: length / 2)]
            if item.item.kind == .effect { visualClips[1].source = visualClips[0].source; visualClips[1].effects = [.init(definitionID: descriptor.id)] }
            else { timeline.transitions = [.init(definitionID: descriptor.id, attachment: .between(outgoing: visualClips[0].id, incoming: visualClips[1].id), duration: min(1, length / 3))] }
        }
        guard !visualClips.isEmpty else { throw MarketplaceAuthoringError.invalid("Add at least one shot before rendering.") }
        let videoTrack = timeline.tracks.firstIndex { $0.kind == .video }!
        timeline.tracks[videoTrack].clips = visualClips
        let resolver = Resolver(files: files)
        let staging = directory.appendingPathComponent("render-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: staging) }
        var options = TimelineExporter.Options(); options.resolution = .p720; options.video = .h264; options.container = .mp4
        try await TimelineExporter.export(timeline, resolver: resolver, to: staging, options: options) { fraction in Task { @MainActor in progress(0.4 + fraction * 0.6) } }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: staging)); generator.appliesPreferredTrackTransform = true
        let image = try await generator.image(at: CMTime(seconds: min(timeline.duration / 2, 2), preferredTimescale: 600)).image
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw MarketplaceAuthoringError.invalid("Could not create the preview cover.") }
        try png.write(to: cover, options: .atomic)
        if FileManager.default.fileExists(atPath: video.path) { try FileManager.default.removeItem(at: video) }
        try FileManager.default.moveItem(at: staging, to: video)
        return Output(video: video, cover: cover)
    }
    static func mockImage(itemId: String, name: String, prompt: String) async throws -> URL {
        let service = MarketplaceAuthoringService.shared
        let path = try service.directory(for: itemId).appendingPathComponent("\(name).png")
        if FileManager.default.fileExists(atPath: path.path) { return path }
        let document = try service.workspace(itemId: itemId)
        let context = document.container.mainContext
        let project = (try? context.fetch(FetchDescriptor<ImageGenProject>(predicate: #Predicate { $0.name == name })).first) ?? ImageGenProject(name: name)
        if project.modelContext == nil { project.prompt = prompt; context.insert(project); try context.save() }
        if let saved = project.generatedFiles.last {
            try savePNG(from: document.storage.absoluteURL(for: saved.imageFilePath), to: path)
            return path
        }
        let config = try AppConfig.loadFromKeychain()
        if config.subscriptionImageModel.isEmpty { project.subscriptionModel = try await BackendModelCatalog.shared.models(capability: .image).first?.id ?? "" }
        let result = try await ImageGenerationService.generate(project: project, context: context, config: config)
        try context.save()
        try savePNG(from: document.storage.absoluteURL(for: result.imageFilePath), to: path)
        return path
    }
    private static func savePNG(from source: URL, to destination: URL) throws {
        guard let image = NSImage(contentsOf: source), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw MarketplaceAuthoringError.invalid("The generated image could not be read.")
        }
        try png.write(to: destination, options: .atomic)
    }
    private static func register(_ descriptor: CIFilterModifierDescriptor) {
        let old = ModifierCatalog.installed
        let effects = descriptor.kind == .effect ? old.effects + [CIFilterEffect(descriptor)] : old.effects
        let transitions = descriptor.kind == .transition ? old.transitions + [CIFilterTransition(descriptor)] : old.transitions
        ModifierCatalog.setInstalled(.init(effects: effects, transitions: transitions, previewURLs: old.previewURLs))
    }
    static func drawSpecimen(title: String, font: NSFont, to path: URL) throws {
        let image = NSImage(size: NSSize(width: 1280, height: 720))
        image.lockFocus(); defer { image.unlockFocus() }
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1280, height: 720).fill()
        let text = "\(title)\n\nThe quick brown fox\njumps over the lazy dog.\n0123456789"
        (text as NSString).draw(in: NSRect(x: 65, y: 60, width: 1150, height: 600), withAttributes: [.font: font, .foregroundColor: NSColor.white])
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { throw MarketplaceAuthoringError.invalid("Could not render the font specimen.") }
        try png.write(to: path, options: .atomic)
    }
}
