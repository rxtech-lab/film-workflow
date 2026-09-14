import AVFoundation
import CryptoKit
import ImageIO
import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

nonisolated struct MarketplaceCategory: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var kind: MarketplaceKind
    var slug: String
    var name: String
    /// SF Symbol for the sidebar row; nil from a server that predates it.
    var icon: String?
}
/// Text an admin has entered in the languages the item is not written in,
/// keyed by locale then field: `["zh-Hans": ["title": "极简片头"]]`.
///
/// Only the authoring side ever sees this. A reader is sent the text already
/// resolved for its `Accept-Language`, so nothing outside the editor has to
/// know a translation exists.
typealias MarketplaceTranslations = [String: [String: String]]

nonisolated struct MarketplaceAuthoringItem: Codable, Identifiable, Sendable {
    var item: MarketplaceItem
    /// Absent from a server that predates translations.
    var translations: MarketplaceTranslations? = nil
    var categoryId: String
    var status: String
    var updatedAt: String
    var contentText: String?
    var contentDownloadUrl: URL?
    var contentRevision: String? = nil
    var id: String { item.id }
    var template: ProjectTemplateDefinition? {
        guard item.kind == .projectTemplate, let contentText else { return nil }
        return try? ProjectTemplateDefinition.decode(Data(contentText.utf8))
    }
}
nonisolated struct MarketplaceItemInput: Codable, Sendable {
    var draftId: String?
    var kind: MarketplaceKind = .projectTemplate
    var categoryId: String = ""
    var title: String = ""
    var description: String = ""
    var pricePoints: Int = 0
    var metadata: MarketplaceItemMetadata = .init()
    /// The title and description in the app's other languages. The form's
    /// boxes for these come from the server's schema, so a language added
    /// there needs no release here.
    var translations: MarketplaceTranslations = [:]
    init() {}
    init(_ value: MarketplaceAuthoringItem) {
        kind = value.item.kind; categoryId = value.categoryId; title = value.item.title
        description = value.item.description; pricePoints = value.item.pricePoints; metadata = value.item.metadata
        translations = value.translations ?? [:]
    }
}
nonisolated struct MarketplaceAuthoringPage: Codable, Sendable {
    var items: [MarketplaceAuthoringItem]
    var page: Int
    var pageCount: Int
    var total: Int
}
nonisolated struct MarketplaceAuthoringJob: Codable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var itemId: String
    var userId: String
    var operation: String
    var state: String = "queued"
    var progress: Double = 0
    var message: String = "Preparing"
    var outputPath: String?
    var coverPath: String?
    var role: String?
    var mock: Bool = false
    var generationKind: String?
    var prompt: String?
    var previewStart: Double?
    var uploadMetadata: MarketplaceItemMetadata?
    var previewDuration: Double?
    var demoPath: String?
    var updatedAt: Date = Date()
    var isFinished: Bool { ["succeeded", "failed", "interrupted"].contains(state) }
}

/// The editor and MCP handlers share all writes, uploads and operation state.
@MainActor @Observable
final class MarketplaceAuthoringService {
    static let shared: MarketplaceAuthoringService = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-marketplaceAuthoringUITest") { return MarketplaceAuthoringFixtures.service() }
        #endif
        return MarketplaceAuthoringService()
    }()
    private(set) var canAuthor = false
    private(set) var userId: String?
    private(set) var jobs: [String: MarketplaceAuthoringJob] = [:]
    /// The authoring form as the backend describes it, fetched once per launch.
    private var formSchema: MarketplaceFormSchema?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var workspaces: [String: ProjectDocument] = [:]
    private let base = "api/v1/admin/marketplace"
    typealias Transport = @MainActor (String, String, Data?) async throws -> Data
    private let transport: Transport?
    private let root: URL
    private let authenticated: @MainActor () -> Bool
    init(root: URL = FileStorage.appSupportURL, authenticated: @escaping @MainActor () -> Bool = { AuthManager.shared.isAuthenticated }, transport: Transport? = nil) {
        self.root = root; self.authenticated = authenticated; self.transport = transport
    }

    func clearAccess() { canAuthor = false; userId = nil; jobs = [:] }
    @discardableResult func refreshAccess() async -> Bool {
        guard authenticated() else { clearAccess(); return false }
        do { try await requireAdmin(); return true } catch { clearAccess(); return false }
    }
    @discardableResult func requireAdmin() async throws -> String {
        struct Capabilities: Decodable { var canAuthor: Bool; var userId: String }
        let value: Capabilities
        do { value = try await request("capabilities") }
        catch { clearAccess(); throw error }
        guard value.canAuthor else { clearAccess(); throw MarketplaceAuthoringError.adminRequired }
        if userId != value.userId { jobs = [:]; workspaces = [:] }
        userId = value.userId; canAuthor = true
        return value.userId
    }
    func directory(for itemId: String) throws -> URL {
        guard let userId, UUID(uuidString: itemId) != nil else { throw MarketplaceAuthoringError.adminRequired }
        let account = SHA256.hash(data: Data(userId.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = root.appendingPathComponent("MarketplaceAuthoring/\(account)/\(itemId)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func workspace(itemId: String) throws -> ProjectDocument {
        if let existing = workspaces[itemId] { return existing }
        let path = try directory(for: itemId).appendingPathComponent("Preview.rxfilmstudio")
        let document = FileManager.default.fileExists(atPath: path.path) ? try ProjectDocument.open(path) : try ProjectDocument.create(at: path)
        workspaces[itemId] = document
        return document
    }
    func document(id: UUID) -> ProjectDocument? { workspaces.values.first { $0.id == id } }
    func document(forContainer container: ModelContainer) -> ProjectDocument? { workspaces.values.first { $0.container === container } }
    /// The form the editor draws. The backend owns the fields, so both the
    /// website and the app show the same ones.
    func schema() async throws -> MarketplaceFormSchema {
        if let formSchema { return formSchema }
        let loaded: MarketplaceFormSchema = try await request("form-schema")
        formSchema = loaded
        return loaded
    }
    func categories() async throws -> [MarketplaceCategory] {
        struct Result: Decodable { var categories: [MarketplaceCategory] }
        let response: Result = try await request("categories"); return response.categories
    }
    /// `icon` is an SF Symbol name; blank leaves the backend's default folder.
    func createCategory(kind: MarketplaceKind, name: String, icon: String = "") async throws -> MarketplaceCategory {
        struct Input: Encodable { var kind: MarketplaceKind; var name: String; var icon: String? }
        struct Result: Decodable { var category: MarketplaceCategory }
        let trimmed = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: Result = try await request("categories", method: "POST", body: Input(kind: kind, name: name, icon: trimmed.isEmpty ? nil : trimmed))
        return result.category
    }
    /// Renames a category or gives it a different sidebar symbol. The slug is
    /// what published items filter on, so it stays put and is not patchable.
    func updateCategory(id: String, name: String, icon: String = "") async throws -> MarketplaceCategory {
        struct Input: Encodable { var name: String; var icon: String? }
        struct Result: Decodable { var category: MarketplaceCategory }
        let trimmed = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: Result = try await request("categories/\(id)", method: "PATCH", body: Input(name: name, icon: trimmed.isEmpty ? nil : trimmed))
        return result.category
    }
    func list(page: Int = 1, mine: Bool = false, status: String? = nil, query: String = "") async throws -> MarketplaceAuthoringPage {
        var parameters = [URLQueryItem(name: "page", value: String(page))]
        if mine { parameters.append(.init(name: "scope", value: "mine")) }
        if let status { parameters.append(.init(name: "status", value: status)) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parameters.append(.init(name: "q", value: trimmed)) }
        if let transport {
            var url = URLComponents(); url.path = "items"; url.queryItems = parameters
            return try decode(await transport(url.string!, "GET", nil))
        }
        return try await BackendClient.shared.get("\(base)/items", query: parameters)
    }
    func get(_ id: String) async throws -> MarketplaceAuthoringItem { try await request("items/\(id)") }
    func save(_ input: MarketplaceItemInput, id: String? = nil, content: String? = nil) async throws -> MarketplaceAuthoringItem {
        _ = try await requireAdmin()
        struct Result: Decodable { var ok: Bool; var id: String? }
        let result: Result = try await request(id.map { "items/\($0)" } ?? "items", method: id == nil ? "POST" : "PATCH", body: input)
        guard let savedId = id ?? result.id else { throw MarketplaceAuthoringError.invalid("The draft was not saved.") }
        if let content { try await saveContent(itemId: savedId, text: content) }
        return try await get(savedId)
    }
    func saveContent(itemId: String, text: String) async throws {
        struct Input: Encodable { var text: String }; struct Result: Decodable { var ok: Bool }
        let _: Result = try await request("items/\(itemId)/content", method: "PUT", body: Input(text: text))
    }
    /// Removes the item and its files. The backend refuses once anyone has
    /// bought it, so this can only ever throw that away, never a purchase.
    func delete(_ id: String) async throws {
        _ = try await requireAdmin()
        struct Result: Decodable { var ok: Bool }
        let _: Result = try await request("items/\(id)", method: "DELETE")
        for job in jobs.values where job.itemId == id { jobs[job.id] = nil }
    }
    func publish(_ id: String, published: Bool) async throws -> MarketplaceAuthoringItem {
        struct Input: Encodable { var published: Bool }; struct Result: Decodable { var ok: Bool }
        let _: Result = try await request("items/\(id)/publish", method: "POST", body: Input(published: published))
        return try await get(id)
    }

    /// Persist the file first. Retrying a network failure never asks a generator to run again.
    /// `metadata` carries facts the file itself cannot be asked for — a
    /// Remotion archive's composition size, duration and prompt. It is merged
    /// over whatever probing finds.
    func upload(itemId: String, role: String, file: URL, mock: Bool = false, jobId: String? = nil, metadata: MarketplaceItemMetadata? = nil) async throws -> MarketplaceAuthoringItem {
        let account = try await requireAdmin()
        guard ["content", "preview-image", "preview-video"].contains(role), file.isFileURL else { throw MarketplaceAuthoringError.invalid("Choose a valid asset slot and local file.") }
        let directory = try directory(for: itemId)
        var file = file
        let item = try await get(itemId)
        if role == "content", [.audio, .soundEffect].contains(item.item.kind), ["mp4", "mov"].contains(file.pathExtension.lowercased()) {
            let output = directory.appendingPathComponent("audio-\(jobId ?? UUID().uuidString).m4a")
            if !FileManager.default.fileExists(atPath: output.path) {
                guard let session = AVAssetExportSession(asset: AVURLAsset(url: file), presetName: AVAssetExportPresetAppleM4A) else { throw MarketplaceAuthoringError.invalid("Could not extract audio from this clip.") }
                try await session.export(to: output, as: .m4a)
            }
            file = output
        }
        var job = MarketplaceAuthoringJob(itemId: itemId, userId: account, operation: "upload", role: role, mock: mock)
        job.uploadMetadata = metadata
        if let jobId { job.id = jobId }
        let staged = file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL && file.lastPathComponent.hasPrefix(job.id + "-") ? file : directory.appendingPathComponent("\(job.id)-\(file.lastPathComponent)")
        if staged.standardizedFileURL != file.standardizedFileURL && !FileManager.default.fileExists(atPath: staged.path) {
            try FileManager.default.copyItem(at: file, to: staged)
        }
        job.outputPath = staged.path; job.state = "running"; job.message = "Uploading \(role.replacingOccurrences(of: "-", with: " "))"
        try persist(job)
        do {
            try await transfer(itemId: itemId, role: role, file: staged, mock: mock, supplied: metadata)
            job.state = "succeeded"; job.progress = 1; job.message = "Uploaded"; try persist(job)
            return try await get(itemId)
        } catch {
            job.state = "failed"; job.message = error.localizedDescription; try? persist(job); throw error
        }
    }
    func retryUpload(job: MarketplaceAuthoringJob) async throws -> MarketplaceAuthoringItem {
        guard job.operation == "upload", let path = job.outputPath, let role = job.role else { throw MarketplaceAuthoringError.invalid("This operation is not an upload.") }
        guard try await requireAdmin() == job.userId else { throw MarketplaceAuthoringError.adminRequired }
        return try await upload(itemId: job.itemId, role: role, file: URL(fileURLWithPath: path), mock: job.mock, jobId: job.id, metadata: job.uploadMetadata)
    }
    private func transfer(itemId: String, role: String, file: URL, mock: Bool, supplied: MarketplaceItemMetadata? = nil) async throws {
        struct Upload: Encodable {
            var itemId: String; var role: String; var filename: String; var contentType: String; var sizeBytes: Int
            var objectKey: String?; var metadata: MarketplaceItemMetadata?
        }
        struct Authorized: Decodable { var uploadURL: URL; var objectKey: String; var headers: [String: String] }
        struct Result: Decodable { var ok: Bool }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var upload = Upload(itemId: itemId, role: role, filename: file.lastPathComponent, contentType: type, sizeBytes: size)
        let authorization: Authorized = try await request("uploads", method: "POST", body: upload)
        var put = URLRequest(url: authorization.uploadURL); put.httpMethod = "PUT"; put.timeoutInterval = 300
        for (key, value) in authorization.headers { put.setValue(value, forHTTPHeaderField: key) }
        let (_, response) = try await URLSession.shared.upload(for: put, fromFile: file)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw MarketplaceAuthoringError.invalid("The upload did not finish. Retry the saved file.") }
        upload.objectKey = authorization.objectKey
        var metadata = MarketplaceItemMetadata()
        if role == "preview-video" || ["mp4", "mov", "m4a", "wav", "mp3", "aac"].contains(file.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: file)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw MarketplaceAuthoringError.invalid("The media has no playable duration.") }
            metadata.durationSeconds = duration
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let oriented = size.applying(transform)
                metadata.width = Int(abs(oriented.width)); metadata.height = Int(abs(oriented.height))
            }
        }
        // A still carries dimensions but no duration; nothing above reads them.
        if ["png", "jpg", "jpeg", "webp"].contains(file.pathExtension.lowercased()),
           let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            metadata.width = properties[kCGImagePropertyPixelWidth] as? Int
            metadata.height = properties[kCGImagePropertyPixelHeight] as? Int
        }
        if role == "preview-video" { metadata.preview = .init(mock: mock) }
        if role == "content", ["ttf", "otf"].contains(file.pathExtension.lowercased()) { metadata.fontFamily = MarketplaceFonts.familyName(of: file) }
        // What the caller knows wins: an archive tells the probe nothing.
        if let supplied {
            metadata.width = supplied.width ?? metadata.width
            metadata.height = supplied.height ?? metadata.height
            metadata.durationSeconds = supplied.durationSeconds ?? metadata.durationSeconds
            metadata.promptExcerpt = supplied.promptExcerpt ?? metadata.promptExcerpt
            if role == "preview-video" { metadata.preview?.startSeconds = supplied.preview?.startSeconds }
        }
        upload.metadata = metadata
        let _: Result = try await request("uploads/finalize", method: "POST", body: upload)
    }
    func localContent(_ item: MarketplaceAuthoringItem) async throws -> URL {
        let directory = try directory(for: item.id)
        let name = item.item.contentFilename ?? "content.json"
        let ext = (name as NSString).pathExtension
        let fingerprint = SHA256.hash(data: Data((item.contentRevision ?? item.updatedAt).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let local = directory.appendingPathComponent("content-\(fingerprint).\(ext)")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        if let text = item.contentText { try Data(text.utf8).write(to: local, options: .atomic); return local }
        guard let url = item.contentDownloadUrl else { throw MarketplaceAuthoringError.invalid("Supply the item's content first.") }
        try await MarketplaceDownloader.download(from: url, to: local)
        return local
    }
    func persist(_ job: MarketplaceAuthoringJob) throws {
        var job = job; job.updatedAt = Date()
        let directory = try directory(for: job.itemId)
        try JSONEncoder().encode(job).write(to: directory.appendingPathComponent("job-\(job.id).json"), options: .atomic)
        jobs[job.id] = job
    }
    func savedJobs(itemId: String) throws -> [MarketplaceAuthoringJob] {
        let directory = try directory(for: itemId)
        for path in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where path.lastPathComponent.hasPrefix("job-") {
            if var job = try? JSONDecoder().decode(MarketplaceAuthoringJob.self, from: Data(contentsOf: path)), job.userId == userId {
                if !job.isFinished && tasks[job.id] == nil { job.state = "interrupted"; job.message = "Interrupted. Completed files are saved for retry." }
                jobs[job.id] = job
            }
        }
        return jobs.values.filter { $0.itemId == itemId }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func startPreview(itemId: String, start: Double = 0, duration: Double = 15, demoPath: String? = nil, existingJob: MarketplaceAuthoringJob? = nil) async throws -> MarketplaceAuthoringJob {
        let account = try await requireAdmin()
        let item = try await get(itemId)
        if let current = jobs.values.first(where: { $0.itemId == itemId && $0.operation == "preview" && !($0.isFinished) }) { return current }
        var job = existingJob ?? MarketplaceAuthoringJob(itemId: itemId, userId: account, operation: "preview", mock: item.item.kind == .projectTemplate)
        job.previewStart = start; job.previewDuration = duration; job.demoPath = demoPath; job.state = "queued"
        let started = job
        try persist(job)
        tasks[job.id] = Task { @MainActor in
            var current = started
            do {
                current.state = "running"; current.message = "Rendering preview"; try persist(current)
                let output = try await MarketplacePreviewRenderer.render(item: item, start: start, duration: duration, demoPath: demoPath) { fraction in
                    current.progress = fraction * 0.8; try? self.persist(current)
                }
                current.outputPath = output.video.path; current.coverPath = output.cover.path; current.message = "Uploading preview"; try persist(current)
                _ = try await upload(itemId: itemId, role: "preview-image", file: output.cover)
                var previewMetadata = MarketplaceItemMetadata()
                previewMetadata.preview = .init(startSeconds: max(0, start))
                _ = try await upload(itemId: itemId, role: "preview-video", file: output.video, mock: current.mock, metadata: previewMetadata)
                current.state = "succeeded"; current.progress = 1; current.message = "Preview ready"; try persist(current)
            } catch { current.state = "failed"; current.message = error.localizedDescription; try? persist(current) }
            tasks[job.id] = nil
        }
        return job
    }
    func startGeneration(itemId: String, kind: String, prompt: String, existingJob: MarketplaceAuthoringJob? = nil) async throws -> MarketplaceAuthoringJob {
        let account = try await requireAdmin()
        let item = try await get(itemId)
        guard kind == "image" || (kind == "video" && item.item.kind == .footage) || (kind == "music" && item.item.kind == .audio) else { throw MarketplaceAuthoringError.invalid("Use the video/music generator for the matching item kind, or image for cover art.") }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MarketplaceAuthoringError.invalid("Provide a generation prompt.") }
        var job = existingJob ?? MarketplaceAuthoringJob(itemId: itemId, userId: account, operation: "generate")
        guard tasks[job.id] == nil else { return jobs[job.id] ?? job }
        job.generationKind = kind; job.prompt = prompt; job.role = kind == "image" ? "preview-image" : "content"; job.state = "queued"
        try persist(job)
        let started = job
        tasks[job.id] = Task { @MainActor in
            var current = started
            do {
                current.state = "running"; current.message = "Generating \(kind)"; try persist(current)
                let document = try workspace(itemId: itemId), context = document.container.mainContext
                let config = try AppConfig.loadFromKeychain()
                let file: URL
                if let saved = current.outputPath, FileManager.default.fileExists(atPath: saved) { file = URL(fileURLWithPath: saved) }
                else if kind == "image" {
                    file = try await MarketplacePreviewRenderer.mockImage(itemId: itemId, name: current.id, prompt: prompt)
                } else if kind == "video" {
                    let id = UUID(uuidString: current.id)!
                    let project = (try? context.fetch(FetchDescriptor<VideoGenProject>(predicate: #Predicate { $0.id == id })).first) ?? VideoGenProject(name: item.item.title)
                    if project.modelContext == nil { project.id = id; project.prompt = prompt; project.googleModel = try await BackendModelCatalog.shared.models(capability: .video).first?.id ?? ""; context.insert(project); try context.save() }
                    if let take = project.generatedFiles.last { file = document.storage.absoluteURL(for: take.videoFilePath) }
                    else if let resumed = try await VideoGenerationService.resume(project: project, context: context, config: config) { file = document.storage.absoluteURL(for: resumed.videoFilePath) }
                    else { let take = try await VideoGenerationService.generate(project: project, context: context, config: config); file = document.storage.absoluteURL(for: take.videoFilePath) }
                } else {
                    let id = UUID(uuidString: current.id)!
                    let project = (try? context.fetch(FetchDescriptor<MusicProject>(predicate: #Predicate { $0.id == id })).first) ?? MusicProject(name: item.item.title)
                    if project.modelContext == nil { project.id = id; project.promptText = prompt; project.generalPrompt = prompt; context.insert(project); try context.save() }
                    if let take = project.generatedFiles.last { file = document.storage.absoluteURL(for: take.audioFilePath) }
                    else { let take = try await MusicGenerationService.generate(project: project, context: context, config: config); file = document.storage.absoluteURL(for: take.audioFilePath) }
                }
                try context.save(); current.outputPath = file.path; current.message = "Uploading generated asset"; current.progress = 0.8; try persist(current)
                _ = try await upload(itemId: itemId, role: current.role!, file: file)
                current.state = "succeeded"; current.progress = 1; current.message = "Generated and uploaded"; try persist(current)
            } catch { current.state = "failed"; current.message = error.localizedDescription; try? persist(current) }
            tasks[current.id] = nil
        }
        return started
    }
    func retry(_ job: MarketplaceAuthoringJob) async throws -> MarketplaceAuthoringJob {
        guard try await requireAdmin() == job.userId else { throw MarketplaceAuthoringError.adminRequired }
        if job.operation == "upload" { _ = try await retryUpload(job: job); return jobs[job.id] ?? job }
        if job.operation == "generate", let kind = job.generationKind, let prompt = job.prompt { return try await startGeneration(itemId: job.itemId, kind: kind, prompt: prompt, existingJob: job) }
        if let video = job.outputPath, let cover = job.coverPath {
            _ = try await upload(itemId: job.itemId, role: "preview-image", file: URL(fileURLWithPath: cover))
            var previewMetadata = MarketplaceItemMetadata()
            previewMetadata.preview = .init(startSeconds: max(0, job.previewStart ?? 0))
            _ = try await upload(itemId: job.itemId, role: "preview-video", file: URL(fileURLWithPath: video), mock: job.mock, metadata: previewMetadata)
            var finished = job; finished.state = "succeeded"; finished.progress = 1; finished.message = "Preview uploaded"; try persist(finished); return finished
        }
        return try await startPreview(itemId: job.itemId, start: job.previewStart ?? 0, duration: job.previewDuration ?? 15, demoPath: job.demoPath, existingJob: job)
    }
    private func request<Response: Decodable>(_ path: String, method: String = "GET") async throws -> Response {
        if let transport { return try decode(await transport(path, method, nil)) }
        let data = try await BackendClient.shared.data("\(base)/\(path)", method: method)
        return try decode(data)
    }
    private func request<Input: Encodable, Response: Decodable>(_ path: String, method: String, body: Input) async throws -> Response {
        // Admin APIs and structured definitions use camelCase; public catalog DTOs use snake_case.
        if let transport { return try decode(await transport(path, method, JSONEncoder().encode(body))) }
        let data = try await BackendClient.shared.data("\(base)/\(path)", method: method, body: JSONEncoder().encode(body), contentType: "application/json")
        return try decode(data)
    }
    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }
}
