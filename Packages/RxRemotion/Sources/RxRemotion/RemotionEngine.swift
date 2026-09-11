import AppKit
import CryptoKit
import Foundation
import WebKit

@MainActor
public final class RemotionEngine {
    nonisolated public static let version = "1.1.0"
    public let configuration: RemotionConfiguration
    private lazy var mapMedia = NativeMedia(root: FileManager.default.temporaryDirectory, configuration: configuration)
    private var projects: [URL: RemotionPreparedProject] = [:]
    private var preparing: [URL: Task<RemotionPreparedProject, Error>] = [:]
    public init(configuration: RemotionConfiguration = .init()) { self.configuration = configuration }

    nonisolated public static var resourceURL: URL { Bundle.module.url(forResource: "Web", withExtension: nil)! }
    nonisolated public static var runtimeFingerprint: String {
        let manifest = (try? Data(contentsOf: resourceURL.appendingPathComponent("manifest.json"))) ?? Data()
        return SHA256.hash(data: Data(version.utf8) + manifest).map { String(format: "%02x", $0) }.joined()
    }
    public var configurationFingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: (try? encoder.encode(configuration)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    /// Copies only missing scaffold files. Existing source and configuration are preserved.
    public static func scaffold(at directory: URL, includeComposition: Bool = true) throws {
        let fm = FileManager.default
        let template = Bundle.module.url(forResource: "Template", withExtension: nil)!.resolvingSymlinksInPath().standardizedFileURL
        try fm.createDirectory(at: directory.appendingPathComponent("public"), withIntermediateDirectories: true)
        guard let enumerator = fm.enumerator(at: template, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let source as URL in enumerator {
            guard (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            if !includeComposition, source.lastPathComponent == "Composition.tsx" { continue }
            let path = source.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(template.path + "/") else { throw RemotionError.resource("Invalid scaffold resource path") }
            let destination = directory.appendingPathComponent(String(path.dropFirst(template.path.count + 1)))
            if !fm.fileExists(atPath: destination.path) {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: destination)
            }
        }
    }
    public func prepare(projectURL: URL, entryPoint: String = "src/index.ts") async throws -> RemotionPreparedProject {
        let key = projectURL.resolvingSymlinksInPath().standardizedFileURL
        if let task = preparing[key] {
            let project = try await task.value
            guard project.entryPoint == entryPoint else { throw RemotionError.resource("This project is preparing a different entrypoint. Use a separate engine for concurrent entrypoints.") }
            return project
        }
        if let project = projects[key], project.entryPoint == entryPoint {
            try await project.compileIfNeeded(); return project
        }
        let project = try RemotionPreparedProject(directory: key, entryPoint: entryPoint, configuration: configuration)
        projects[key]?.close(); projects[key] = project
        let task = Task { @MainActor in try await project.start(); try Task.checkCancellation(); return project }
        preparing[key] = task
        defer { preparing[key] = nil }
        do { return try await task.value }
        catch { projects[key] = nil; project.close(); throw error }
    }
    public func compositions(in project: RemotionPreparedProject, inputProps: [String: RemotionJSON] = [:]) async throws -> [RemotionComposition] {
        try await project.compileIfNeeded()
        let page = try await RemotionWebPage(project: project, mode: "discover", compositionID: "Main", inputProps: inputProps, settings: .init())
        defer { page.dispose() }
        return page.compositions
    }
    public func makePreviewSession(project: RemotionPreparedProject, compositionID: String = "Main",
                                   inputProps: [String: RemotionJSON] = [:], settings: RemotionRenderSettings = .init()) async throws -> RemotionPreviewSession {
        try await project.compileIfNeeded()
        return try await RemotionPreviewSession(project: project, compositionID: compositionID, inputProps: inputProps, settings: settings)
    }
    public func renderStill(project: RemotionPreparedProject, compositionID: String = "Main", frame: Int,
                            to output: URL, inputProps: [String: RemotionJSON] = [:], settings: RemotionRenderSettings = .init()) async throws {
        try await project.withFrozenCopy { project in
            let page = try await RemotionWebPage(project: project, mode: "render", compositionID: compositionID, inputProps: inputProps, settings: settings)
            defer { page.dispose() }
            guard let composition = page.compositions.first, (0..<composition.durationInFrames).contains(frame) else {
                throw RemotionError.rendering("Still frame is outside the composition")
            }
            for index in 0...frame { _ = try await page.advance(to: index) }
            let image = try await page.capture()
            try await NativeMedia.writePNG(image, to: output)
        }
    }
    public func snapshotMapKit(_ request: RemotionMapRequest) async throws -> RemotionMapSnapshot {
        try await mapMedia.mapSnapshot(JSONEncoder().encode(request))
    }
    public func close(projectURL: URL) {
        let key = projectURL.resolvingSymlinksInPath().standardizedFileURL
        preparing.removeValue(forKey: key)?.cancel(); projects.removeValue(forKey: key)?.close()
    }
    public func closeAll() { preparing.values.forEach { $0.cancel() }; preparing.removeAll(); mapMedia.cancel(); for project in projects.values { project.close() }; projects.removeAll() }
}

@MainActor
public final class RemotionPreparedProject {
    public let directory: URL
    public let entryPoint: String
    public private(set) var baseURL: URL!
    public private(set) var revision = ""
    public var onRevisionChange: (() -> Void)?
    let configuration: RemotionConfiguration
    let media: NativeMedia
    private let server: ResourceServer
    private var outputs: [String: Data] = [:]
    private var compileTask: Task<Void, Error>?
    private var watcher: Task<Void, Never>?
    private var compilationError: String?
    private var closed = false
    private var fingerprint = ""
    init(directory: URL, entryPoint: String, configuration: RemotionConfiguration) throws {
        self.directory = directory; self.entryPoint = entryPoint; self.configuration = configuration
        server = try ResourceServer(); media = NativeMedia(root: directory, configuration: configuration)
        server.handle = { [weak self] request in
            guard let self, !self.closed else { throw RemotionError.disposed }
            return try await self.respond(request)
        }
    }
    func start(watch: Bool = true) async throws {
        baseURL = try await server.start(); try await compileIfNeeded()
        guard watch else { return }
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, !self.closed else { return }
                try? await self.compileIfNeeded()
            }
        }
    }
    func projectFiles() async throws -> [String] { try await ProjectFiles.list(in: directory) }
    func sourceFingerprint() async throws -> String { try await ProjectFiles.hash(in: directory, entryPoint: entryPoint) }
    public func compileIfNeeded() async throws {
        guard !closed else { throw RemotionError.disposed }
        if let task = compileTask { return try await task.value }
        // Protect the entire async fingerprint/cache/compile operation from reentry.
        let task = Task { @MainActor in try await self.compileCurrentSources() }
        compileTask = task
        defer { compileTask = nil }
        try await task.value
    }
    private func compileCurrentSources() async throws {
        let next = try await sourceFingerprint()
        try Task.checkCancellation()
        guard !closed else { throw RemotionError.disposed }
        if next == fingerprint {
            if let compilationError { throw RemotionError.compilation(compilationError) }; return
        }
        if let cached = await CompilationCache.read(key: next, base: baseURL) {
            try Task.checkCancellation()
            outputs = cached; fingerprint = next; compilationError = nil
            revision = UUID().uuidString; onRevisionChange?(); return
        }
        outputs = ["entry.css": Data()]
        defer { revision = UUID().uuidString; fingerprint = next; onRevisionChange?() }
        do {
            let page = try await RemotionWebPage(project: self, mode: "compile", compositionID: "Main", inputProps: [:], settings: .init())
            page.dispose(); compilationError = nil
            await CompilationCache.write(outputs, key: next, base: baseURL)
        } catch { compilationError = error.localizedDescription; throw error }
    }
    func frozenCopy() async throws -> RemotionPreparedProject {
        let destination = try await ProjectFiles.snapshot(of: directory, entryPoint: entryPoint)
        do {
            let frozen = try RemotionPreparedProject(directory: destination, entryPoint: entryPoint, configuration: configuration)
            do { try await frozen.start(watch: false); return frozen }
            catch { frozen.close(); throw error }
        } catch { await ProjectFiles.remove(destination); throw error }
    }
    func withFrozenCopy<T: Sendable>(_ operation: @MainActor (RemotionPreparedProject) async throws -> T) async throws -> T {
        let frozen = try await frozenCopy()
        do {
            let result = try await operation(frozen)
            frozen.close(); await ProjectFiles.remove(frozen.directory)
            return result
        } catch {
            frozen.close(); await ProjectFiles.remove(frozen.directory)
            throw error
        }
    }
    public func previewURL(compositionID: String = "Main", settings: RemotionRenderSettings = .init()) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("index.html"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "mode", value: "preview"), URLQueryItem(name: "composition", value: compositionID)]
        if let width = settings.width { components.queryItems?.append(URLQueryItem(name: "width", value: "\(width)")) }
        if let height = settings.height { components.queryItems?.append(URLQueryItem(name: "height", value: "\(height)")) }
        return components.url!
    }
    func pageURL(mode: String, compositionID: String, inputProps: [String: RemotionJSON], settings: RemotionRenderSettings) throws -> URL {
        var c = URLComponents(url: previewURL(compositionID: compositionID, settings: settings), resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []).filter { $0.name != "mode" }
        c.queryItems?.append(URLQueryItem(name: "mode", value: mode))
        c.queryItems?.append(URLQueryItem(name: "props", value: String(data: try JSONEncoder().encode(inputProps), encoding: .utf8)!))
        if let fps = settings.fps { c.queryItems?.append(URLQueryItem(name: "fps", value: "\(fps)")) }
        return c.url!
    }
    public func close() {
        guard !closed else { return }; closed = true
        watcher?.cancel(); watcher = nil; compileTask?.cancel(); compileTask = nil
        media.cancel(); server.stop(); outputs.removeAll()
    }
    private func respond(_ request: ResourceRequest) async throws -> ResourceResponse {
        guard let url = URL(string: request.path, relativeTo: baseURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return ResourceResponse(status: 400) }
        let path = String(url.path.dropFirst(baseURL.path.count + 1))
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        switch path {
        case "files": return try .json(await projectFiles())
        case "revision": return try .json(["revision": revision, "error": compilationError ?? ""])
        case "index.html", "":
            let mode = query["mode"] ?? "preview"
            var publicConfig = configuration
            // Provider credentials are used only by Swift's tile transport.
            publicConfig.openStreetMap?.headers = [:]; publicConfig.openStreetMap?.tileURL = ""
            let props = (try? JSONSerialization.jsonObject(with: Data((query["props"] ?? "{}").utf8))) ?? [:]
            let config: [String: Any] = ["base": baseURL.absoluteString, "mode": mode,
                "entryPoint": entryPoint, "compositionID": query["composition"] ?? "Main", "inputProps": props,
                "timeout": configuration.frameTimeout, "revision": revision,
                "settings": ["width": query["width"].flatMap(Int.init) as Any, "height": query["height"].flatMap(Int.init) as Any,
                             "fps": query["fps"].flatMap(Double.init) as Any].compactMapValues { value -> Any? in
                                 let mirror = Mirror(reflecting: value); return mirror.displayStyle == .optional ? mirror.children.first?.value : value
                             },
                "configuration": try JSONSerialization.jsonObject(with: JSONEncoder().encode(publicConfig))]
            let json = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!.replacingOccurrences(of: "<", with: "\\u003c")
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><style>html,body,#stage{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}#registry{display:none}</style>
            <link rel="stylesheet" href="\(baseURL.absoluteString)compiled/entry.css"></head><body><div id="registry"></div><div id="stage"></div>
            <script>const config=\(json);window.rxBase=config.base;window.rxConfig=config.configuration;window.rxMode=config.mode;
            window.process={env:{NODE_ENV:'production'}};window.remotion_staticBase=new URL(config.base).pathname+'public';
            window.remotion_audioEnabled=true;window.remotion_videoEnabled=true;window.remotion_initialFrame=0;window.remotion_attempt=1;
            if(config.mode==='render')window.remotion_puppeteerTimeout=config.timeout*1000;
            window.rxEmit=(type,detail={})=>window.webkit?.messageHandlers?.rxRemotion?.postMessage({type,...detail});
            window.addEventListener('error',e=>{window.rxError=e.message;rxEmit('error',{message:e.message})});
            window.addEventListener('unhandledrejection',e=>{window.rxError=String(e.reason);rxEmit('error',{message:String(e.reason)})});</script>
            \(mode == "render" ? "<script src='\(baseURL.absoluteString)web/capture.js'></script>" : "")
            <script type="module">try{if(config.mode==='compile'){const {compile}=await import(config.base+'web/compiler.js');await compile(config)}
            else{const {start}=await import(config.base+'web/host.js');await start(config);
            if(config.mode==='preview')setInterval(async()=>{const state=await(await fetch(config.base+'revision')).json();
            if(state.error){rxEmit('error',{message:state.error});return}if(state.revision!==config.revision)location.reload()},500)}}
            catch(error){rxEmit('error',{message:error.message||String(error)})}</script></body></html>
            """
            return ResourceResponse(type: "text/html", data: Data(html.utf8))
        case "native/map":
            if query["projection"] == "1" { return try .json(await media.mapSnapshot(request.body)) }
            return ResourceResponse(type: "image/png", data: try await media.map(request.body))
        case "native/video":
            return ResourceResponse(type: "image/png", data: try await media.videoFrame(source: query["src"] ?? "", time: Double(query["time"] ?? "0") ?? 0, base: baseURL))
        default:
            if path.hasPrefix("native/tile/") { return try await media.tile(String(path.dropFirst(12))) }
            if path.hasPrefix("compiled/") {
                let name = String(path.dropFirst(9))
                guard ["entry.js", "entry.css"].contains(name) else { return ResourceResponse(status: 404) }
                if request.method == "PUT" { outputs[name] = request.body; return ResourceResponse(status: 204) }
                if let data = outputs[name] { return ResourceResponse(type: name.hasSuffix(".css") ? "text/css" : "text/javascript", data: data) }
                if name == "entry.css" { return ResourceResponse(type: "text/css") }
                return ResourceResponse(status: 404)
            }
            let file: URL
            if path.hasPrefix("web/") { file = try ResourceServer.containedFile(String(path.dropFirst(4)), root: RemotionEngine.resourceURL) }
            else if path.hasPrefix("source/") { file = try ResourceServer.containedFile(String(path.dropFirst(7)), root: directory) }
            else if path.hasPrefix("public/") { file = try ResourceServer.containedFile(path, root: directory) }
            else { return ResourceResponse(status: 404) }
            return ResourceResponse(type: ResourceServer.mime(file), file: file)
        }
    }
}
