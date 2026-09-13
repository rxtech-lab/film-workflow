import Foundation
import SwiftData
import VideoEditorCore
import VideoEffectsCore

nonisolated struct ProjectTemplateApplication: Codable, Identifiable, Sendable {
    var id: String
    var itemId: String
    var title: String
    var template: ProjectTemplateDefinition
    var sequenceId: UUID
    var footageBindings: [String: String] = [:]
    var dependencySources: [String: String] = [:]
    var missingRequirements: [String] = []
    var dependencyItems: [MarketplaceItem] = []
    var blockers: [String] = []
    var state: String = "collecting"
}

@MainActor enum ProjectTemplateService {
    private static var activeApplications: Set<String> = []
    static func extract(document: ProjectDocument, sequenceId: String?, prompt: String?, marketplaceBindings: [String: String] = [:]) throws -> ProjectTemplateDefinition {
        let context = document.container.mainContext
        let sequences = try context.fetch(FetchDescriptor<SequenceProject>())
        let selected = AppNavigation.shared.currentTarget
        let sequence: SequenceProject
        if let sequenceId { sequence = try MCPLibraryHandlers.fetchSequence(id: sequenceId, context: context) }
        else if let match = sequences.first(where: { $0.id == selected.projectUUID }) { sequence = match }
        else if sequences.count == 1 { sequence = sequences[0] }
        else { throw MarketplaceAuthoringError.invalid("Choose a sequence from sequence_list before turning this film into a template.") }
        var definition = ProjectTemplateDefinition()
        definition.width = sequence.width; definition.height = sequence.height; definition.fps = sequence.fps
        definition.prompt = prompt ?? "Create a new video using the shot plan below. Adapt the subjects to the user's footage."
        definition.videoStyle = sequence.width < sequence.height ? "Portrait composition" : "Landscape composition"
        definition.editingGuidance = "Adapt shot lengths to the supplied footage; preserve the order and transition choices."
        let timeline = sequence.timeline
        var dependencies: [String: ProjectTemplateDefinition.Dependency] = [:]
        let manifests = MarketplaceStore.shared.installed.values
        func recordModifier(_ modifierId: String) throws {
            if let mapped = marketplaceBindings["modifier:" + modifierId] {
                guard UUID(uuidString: mapped) != nil else { throw MarketplaceAuthoringError.invalid("Use a marketplace item identifier for modifier mappings.") }
                dependencies[mapped] = .init(itemId: mapped, purpose: "Modifier: " + modifierId); return
            }
            if ModifierCatalog.standard.effect(modifierId) != nil || ModifierCatalog.standard.transition(modifierId) != nil { return }
            var found = false
            for manifest in manifests where manifest.kind == .effect || manifest.kind == .transition {
                let url = manifest.contentURL(in: MarketplaceStore.shared.directory(for: manifest))
                if let descriptor = try? InstalledModifierLoader.descriptor(at: url, expecting: manifest.kind), descriptor.id == modifierId {
                    dependencies[manifest.itemID] = .init(itemId: manifest.itemID, purpose: manifest.title); found = true
                }
            }
            if !found { throw MarketplaceAuthoringError.invalid("Map modifier \(modifierId) to a marketplace item using marketplace_bindings, or choose a built-in replacement before extracting.") }
        }
        let clips = timeline.tracks.filter { $0.kind != .overlay }.flatMap(\.clips).sorted { $0.start < $1.start }
        for (index, clip) in clips.enumerated() {
            let id = "shot-\(index + 1)"
            let details = sourceDetails(clip.source.id, context: context)
            let type = clip.source.kind == .audio ? "audio" : clip.source.kind == .image ? "image" : "video"
            var instructions = portable(details.prompt.isEmpty ? "Provide \(type) for \(clip.source.displayName), approximately \(Int(clip.duration.rounded())) seconds." : details.prompt)
            if clip.transform != .identity { instructions += " Framing: \(clip.transform.fit.rawValue), scale \(clip.transform.scale), offset \(clip.transform.offsetX), \(clip.transform.offsetY)." }
            if clip.playbackRate != 1 { instructions += " Playback speed: \(clip.playbackRate)×." }
            if clip.isReversed { instructions += " Play this shot in reverse." }
            var shot = ProjectTemplateDefinition.Shot(id: id, title: "Shot \(index + 1)", instructions: instructions, durationSeconds: clip.duration)
            if let itemId = marketplaceBindings[clip.source.id] ?? details.marketplaceId {
                guard UUID(uuidString: itemId) != nil else { throw MarketplaceAuthoringError.invalid("Use marketplace item identifiers for asset mappings.") }
                dependencies[itemId] = .init(itemId: itemId, purpose: portable(clip.source.displayName))
                shot.marketplaceItemId = itemId
            } else {
                shot.footageRequirementId = id
                definition.footageRequirements.append(.init(id: id, title: shot.title, mediaType: type, required: true, instructions: instructions))
            }
            shot.effects = try clip.effects.filter(\.isEnabled).map { effect in
                try recordModifier(effect.definitionID)
                return .init(modifierId: effect.definitionID, parameters: effect.parameters)
            }
            if let transition = timeline.transitions.first(where: { t in
                if case .between(let outgoing, _) = t.attachment { return outgoing == clip.id && t.isEnabled }; return false
            }) {
                try recordModifier(transition.definitionID)
                shot.transition = .init(modifierId: transition.definitionID, parameters: transition.parameters, durationSeconds: transition.duration)
            }
            definition.shots.append(shot)
        }
        for clip in timeline.allClips {
            if let font = clip.text?.fontName, let manifest = manifests.first(where: { $0.kind == .font && $0.metadata.fontFamily == font }) {
                dependencies[manifest.itemID] = .init(itemId: manifest.itemID, purpose: "Caption font: \(font)")
            }
        }
        let visualClips = clips.filter { $0.source.kind != .audio }
        let average = visualClips.reduce(0) { $0 + $1.duration } / Double(max(1, visualClips.count))
        definition.videoStyle += average < 3 ? "; brisk pacing with short shots." : average > 7 ? "; deliberate pacing with sustained shots." : "; moderate pacing."
        let looks = Set(clips.flatMap { $0.effects.filter(\.isEnabled).compactMap { ModifierCatalog.current.effect($0.definitionID)?.name } }).sorted()
        if !looks.isEmpty { definition.videoStyle += " Visual treatment: " + looks.joined(separator: ", ") + "." }
        definition.marketplaceItems = dependencies.values.sorted { $0.itemId < $1.itemId }
        try definition.validate()
        return definition
    }
    private static func portable(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?:file://|/Users/|/Volumes/|/private/)\S+"#, with: "[user-provided asset]", options: .regularExpression)
    }
    private static func sourceDetails(_ sourceId: String, context: ModelContext) -> (prompt: String, marketplaceId: String?) {
        guard let (prefix, id) = DocumentMediaResolver.parse(sourceId) else { return ("", nil) }
        switch prefix {
        case .imported: return ("", (try? MCPLibraryHandlers.fetchImported(id: id.uuidString, context: context))?.marketplaceItemId)
        case .image:
            let take = try? context.fetch(FetchDescriptor<GeneratedImage>(predicate: #Predicate { $0.id == id })).first
            return (take?.prompt ?? "", nil)
        case .video:
            let take = try? context.fetch(FetchDescriptor<GeneratedVideo>(predicate: #Predicate { $0.id == id })).first
            let project = take?.project
            let prompt = [take?.prompt, project?.negativePrompt.isEmpty == false ? "Avoid: " + (project?.negativePrompt ?? "") : nil].compactMap { $0 }.joined(separator: "\n")
            return (prompt, nil)
        case .music:
            let take = try? context.fetch(FetchDescriptor<GeneratedMusic>(predicate: #Predicate { $0.id == id })).first
            let project = take?.project
            return ([project?.promptText, project?.generalPrompt, project.map { "Music: \($0.genre), \($0.mood), \($0.bpm) BPM. Instruments: \($0.instruments.joined(separator: ", "))." }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"), nil)
        case .narration:
            let take = try? context.fetch(FetchDescriptor<GeneratedNarrative>(predicate: #Predicate { $0.id == id })).first
            return ([take?.project?.sceneDescription, take?.project?.notes, take?.transcriptText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"), nil)
        case .remotion:
            let project = try? MCPLibraryHandlers.fetchRemotion(id: id.uuidString, context: context)
            return (project?.prompt ?? "", project?.marketplaceItemId)
        default: return ("", nil)
        }
    }
    static func source(_ sourceId: String, document: ProjectDocument) throws -> ClipSource {
        guard let (prefix, id) = DocumentMediaResolver.parse(sourceId) else { throw MarketplaceAuthoringError.invalid("Use a sourceId from footage_list for each footage binding.") }
        let kind: SourceKind
        switch prefix {
        case .image: kind = .image
        case .music, .narration: kind = .audio
        case .caption: kind = .captions
        case .remotion: kind = .remotion
        case .video: kind = .video
        case .imported:
            let asset = try MCPLibraryHandlers.fetchImported(id: id.uuidString, context: document.container.mainContext)
            kind = asset.kindEnum == .audio ? .audio : asset.kindEnum == .image ? .image : .video
        }
        return ClipSource(id: sourceId, kind: kind, displayName: "Template footage")
    }
    static func applicationsDirectory(_ document: ProjectDocument) throws -> URL {
        let directory = document.packageURL.appendingPathComponent("TemplateApplications", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static func persist(_ application: ProjectTemplateApplication, document: ProjectDocument) throws {
        guard UUID(uuidString: application.id) != nil else { throw MarketplaceAuthoringError.invalid("Invalid application identifier.") }
        try JSONEncoder().encode(application).write(to: applicationsDirectory(document).appendingPathComponent("\(application.id).json"), options: .atomic)
    }
    static func apply(itemId: String, document: ProjectDocument, applicationId: String?, bindings: [String: String]) async throws -> ProjectTemplateApplication {
        let key = document.id.uuidString + ":" + itemId
        guard activeApplications.insert(key).inserted else { throw MarketplaceAuthoringError.invalid("This template is already being applied to this film. Wait for that operation, then resume it.") }
        defer { activeApplications.remove(key) }
        let directory = try applicationsDirectory(document)
        var application: ProjectTemplateApplication?
        if let applicationId {
            guard UUID(uuidString: applicationId) != nil else { throw MarketplaceAuthoringError.invalid("Invalid application identifier.") }
            let file = directory.appendingPathComponent("\(applicationId).json")
            if FileManager.default.fileExists(atPath: file.path) { application = try JSONDecoder().decode(ProjectTemplateApplication.self, from: Data(contentsOf: file)) }
        } else {
            // Repeated initial tool calls reuse the existing application. A fresh explicit UUID requests another edit.
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" {
                if let saved = try? JSONDecoder().decode(ProjectTemplateApplication.self, from: Data(contentsOf: file)), saved.itemId == itemId { application = saved; break }
            }
        }
        let client = MarketplaceClient(), store = MarketplaceStore.shared
        let item = try await client.item(itemId)
        guard item.kind == .projectTemplate, item.isEntitled else { throw MarketplaceAuthoringError.invalid("Buy the template before applying it.") }
        if application == nil {
            if !store.isInstalled(itemId) { guard await store.install(item) else { throw MarketplaceAuthoringError.invalid(store.lastError ?? "Could not install the template.") } }
            guard let manifest = store.manifest(for: itemId) else { throw MarketplaceError.notInstalled }
            let template = try ProjectTemplateDefinition.decode(Data(contentsOf: manifest.contentURL(in: store.directory(for: manifest))))
            application = .init(id: applicationId ?? UUID().uuidString, itemId: itemId, title: item.title, template: template, sequenceId: UUID())
            try persist(application!, document: document)
        }
        return try await advance(application!, expectedItemId: itemId, document: document, bindings: bindings)
    }
    /// Kept separate from catalog lookup so recovery and sequence preservation can be tested with local fixtures.
    static func advance(_ initial: ProjectTemplateApplication, expectedItemId: String, document: ProjectDocument, bindings: [String: String], resolveDependencies: Bool = true) async throws -> ProjectTemplateApplication {
        var application = initial
        guard application.itemId == expectedItemId else { throw MarketplaceAuthoringError.invalid("This application belongs to a different template.") }
        try application.template.validate()
        guard Set(bindings.keys).isSubset(of: Set(application.template.footageRequirements.map(\.id))) else { throw MarketplaceAuthoringError.invalid("A footage binding names an unknown requirement.") }
        let context = document.container.mainContext
        let sequence = (try? MCPLibraryHandlers.fetchSequence(id: application.sequenceId.uuidString, context: context)) ?? {
            let new = SequenceProject(name: "\(application.title) — Template")
            new.id = application.sequenceId; var timeline = new.timeline; timeline.id = new.id; new.timeline = timeline
            context.insert(new); return new
        }()
        try context.save()
        application.footageBindings.merge(bindings) { _, new in new }
        application.missingRequirements = []; application.blockers = []; application.dependencyItems = []
        let resolver = DocumentMediaResolver(document: document, width: application.template.width, height: application.template.height, fps: application.template.fps)
        for requirement in application.template.footageRequirements {
            guard let sourceId = application.footageBindings[requirement.id] else {
                if requirement.required { application.missingRequirements.append(requirement.id) }; continue
            }
            do {
                let source = try source(sourceId, document: document)
                let matches = requirement.mediaType == "audio" ? source.kind == .audio : requirement.mediaType == "image" ? source.kind == .image : source.kind == .video || source.kind == .remotion
                guard matches else { throw MarketplaceAuthoringError.invalid("\(requirement.title) needs \(requirement.mediaType).") }
                _ = try await resolver.resolve(source)
            } catch { application.blockers.append("\(requirement.title): \(error.localizedDescription)") }
        }
        if resolveDependencies {
            for reference in application.template.marketplaceItems {
                do {
                    let item = try await MarketplaceClient().item(reference.itemId)
                    application.dependencyItems.append(item)
                    guard item.isEntitled else { if reference.required { application.blockers.append("Buy \(item.title) for \(item.pricePoints) credits.") }; continue }
                    let store = MarketplaceStore.shared
                    if !store.isInstalled(item.id) { guard await store.install(item) else { throw MarketplaceAuthoringError.invalid(store.lastError ?? "Could not install dependency.") } }
                    if item.kind.addsToFilm && application.dependencySources[item.id] == nil, let manifest = store.manifest(for: item.id) {
                        let library = try await MarketplaceInstaller.addToFilm(manifest, contentURL: manifest.contentURL(in: store.directory(for: manifest)), document: document)
                        let added = try MCPLibraryHandlers.item(id: library.id.uuidString, context: context)
                        application.dependencySources[item.id] = MCPLibraryHandlers.summary(added, context: context)["sourceId"] as? String
                        try persist(application, document: document)
                    }
                } catch { if reference.required { application.blockers.append("\(reference.purpose): \(error.localizedDescription)") } }
            }
        }
        guard application.missingRequirements.isEmpty, application.blockers.isEmpty else {
            application.state = "collecting"; try persist(application, document: document); return application
        }
        if initial.state == "ready", bindings.isEmpty { try persist(application, document: document); return application }
        var timeline = Timeline(id: sequence.id, width: application.template.width, height: application.template.height, fps: application.template.fps)
        var time: Double = 0
        var previous: (Clip, ProjectTemplateDefinition.Shot)?
        for shot in application.template.shots {
            let id = shot.footageRequirementId.flatMap { application.footageBindings[$0] } ?? shot.marketplaceItemId.flatMap { application.dependencySources[$0] }
            guard let id else { continue }
            let source = try source(id, document: document)
            let media: ResolvedMedia?
            if source.kind == .remotion {
                media = try? await resolver.resolve(source)
                if media == nil { application.blockers.append("Prepare and render Remotion composition \(source.id) from its prompt in the new sequence, then resume this application.") }
            } else { media = try await resolver.resolve(source) }
            var length = shot.durationSeconds
            if case .file(_, let natural, _)? = media, let natural { length = min(length, natural) }
            guard length.isFinite, length > 0 else { throw MarketplaceAuthoringError.invalid("\(shot.title) has no usable media.") }
            let effects = try shot.effects.map { value -> EffectInstance in
                guard ModifierCatalog.current.effect(value.modifierId) != nil else { throw MarketplaceAuthoringError.invalid("Missing effect: \(value.modifierId)") }
                return .init(definitionID: value.modifierId, parameters: value.parameters)
            }
            let clip = Clip(source: source, start: time, duration: length, effects: effects)
            let track = timeline.tracks.firstIndex { $0.kind == (source.kind == .audio ? .audio : .video) }!
            timeline.tracks[track].clips.append(clip)
            if source.kind != .audio {
                if let (last, lastShot) = previous, let transition = lastShot.transition, abs(last.end - clip.start) < 0.001 {
                    guard ModifierCatalog.current.transition(transition.modifierId) != nil else { throw MarketplaceAuthoringError.invalid("Missing transition: \(transition.modifierId)") }
                    timeline.transitions.append(.init(definitionID: transition.modifierId, parameters: transition.parameters, attachment: .between(outgoing: last.id, incoming: clip.id), duration: min(transition.durationSeconds ?? 0.5, min(last.duration, clip.duration) / 2)))
                }
                previous = (clip, shot); time += length
            }
        }
        let shotDependencies = Set(application.template.shots.compactMap(\.marketplaceItemId))
        for reference in application.template.marketplaceItems where !shotDependencies.contains(reference.itemId) {
            guard let sourceId = application.dependencySources[reference.itemId] else { continue }
            let source = try source(sourceId, document: document)
            guard source.kind == .audio, time > 0 else { continue }
            let media = try await resolver.resolve(source)
            var duration = time
            if case .file(_, let natural, _) = media, let natural { duration = min(duration, natural) }
            if duration > 0 { let track = timeline.tracks.firstIndex { $0.kind == .audio }!; timeline.tracks[track].clips.append(.init(source: source, start: 0, duration: duration)) }
        }
        try timeline.validateModifiers(requireDefinitions: true)
        sequence.timeline = timeline; try context.save()
        if !timeline.tracks.contains(where: { $0.kind == .video && !$0.clips.isEmpty }) { application.blockers.append("Provide at least one visual shot to build this video.") }
        application.state = application.blockers.isEmpty ? "ready" : "collecting"; try persist(application, document: document)
        NotificationCenter.default.post(name: .agentDidMutateProject, object: nil)
        return application
    }
}
