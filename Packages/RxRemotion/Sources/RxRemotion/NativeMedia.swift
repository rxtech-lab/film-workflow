import AppKit
import AVFoundation
import CryptoKit
import MapKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class NativeMedia {
    private var generators: [URL: AVAssetImageGenerator] = [:]
    private var videoJobs: [String: Task<Data, Error>] = [:]
    private var videoTails: [URL: (key: String, job: Task<Data, Error>)] = [:]
    private var videoFrames: [String: Data] = [:]
    private var videoFrameOrder: [String] = []
    private var videoFrameBytes = 0
    private var cameraSnapshot: (key: String, value: MKMapSnapshotter.Snapshot)?
    private var snapshots: [String: RemotionMapSnapshot] = [:]
    private var mapJobs: [String: Task<RemotionMapSnapshot, Error>] = [:]
    private let configuration: RemotionConfiguration
    private let root: URL
    init(root: URL, configuration: RemotionConfiguration) { self.root = root; self.configuration = configuration }

    func resolve(_ source: String, base: URL) throws -> URL {
        guard let url = URL(string: source, relativeTo: base)?.absoluteURL else { throw RemotionError.resource("Invalid media URL") }
        if url.host == base.host, url.port == base.port {
            let prefix = base.path + "/"
            guard url.path.hasPrefix(prefix) else { throw RemotionError.resource("Media is outside this project") }
            let path = String(url.path.dropFirst(prefix.count))
            if path.hasPrefix("public/") { return try ResourceServer.containedFile(path, root: root) }
            if path.hasPrefix("source/") { return try ResourceServer.containedFile(String(path.dropFirst(7)), root: root) }
            throw RemotionError.resource("Invalid project media URL")
        }
        guard url.scheme == "https" || url.scheme == "http" else { throw RemotionError.unsupported("Media must be a project asset or HTTP(S) URL") }
        return url
    }

    func videoFrame(source: String, time: Double, base: URL) async throws -> Data {
        guard time.isFinite, time >= 0 else { throw RemotionError.rendering("Invalid media time") }
        let url = try resolve(source, base: base)
        let generator: AVAssetImageGenerator
        if let cached = generators[url] { generator = cached }
        else {
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generators[url] = generator
        }
        let key = url.absoluteString + "@" + String(time)
        if let cached = videoFrames[key] { return cached }
        if let pending = videoJobs[key] { return try await pending.value }
        let previous = videoTails[url]?.job
        let job = Task { @MainActor in
            // AVAssetImageGenerator is reused, but never receives overlapping requests.
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            let image: CGImage = try await withCheckedThrowingContinuation { continuation in
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: time, preferredTimescale: 60000))]) { _, image, _, result, error in
                    if let image, result == .succeeded { continuation.resume(returning: image) }
                    else if result == .cancelled { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume(throwing: error ?? RemotionError.rendering("Media frame decoding failed")) }
                }
            }
            return try await Self.png(image)
        }
        videoJobs[key] = job; videoTails[url] = (key, job)
        defer {
            videoJobs[key] = nil
            if videoTails[url]?.key == key { videoTails[url] = nil }
        }
        let data = try await job.value
        // Workers replay the same media positions; reuse those decodes without
        // retaining an entire movie's worth of frames.
        if data.count <= 32 * 1024 * 1024 {
            videoFrames[key] = data; videoFrameOrder.append(key); videoFrameBytes += data.count
            while videoFrameBytes > 32 * 1024 * 1024, !videoFrameOrder.isEmpty {
                videoFrameBytes -= videoFrames.removeValue(forKey: videoFrameOrder.removeFirst())?.count ?? 0
            }
        }
        return data
    }

    @concurrent nonisolated static func writePNG(_ image: CGImage, to output: URL) async throws {
        let data = try await png(image)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
    }
    @concurrent nonisolated static func png(_ image: CGImage) async throws -> Data {
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RemotionError.rendering("Could not create the PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RemotionError.rendering("Could not encode the captured frame") }
        return data as Data
    }

    @MainActor private final class MapOperation {
        let snapshotter: MKMapSnapshotter
        init(_ snapshotter: MKMapSnapshotter) { self.snapshotter = snapshotter }
    }
    func map(_ data: Data) async throws -> Data { try await mapSnapshot(data).png }
    func mapSnapshot(_ data: Data) async throws -> RemotionMapSnapshot {
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let cached = snapshots[key] { return cached }
        if let job = mapJobs[key] { return try await job.value }
        let request = try JSONDecoder().decode(RemotionMapRequest.self, from: data)
        guard CLLocationCoordinate2DIsValid(request.center.value), request.zoom.isFinite,
              (0...22).contains(request.zoom), (1...8192).contains(request.width), (1...8192).contains(request.height),
              request.markers.allSatisfy({ CLLocationCoordinate2DIsValid($0.coordinate.value) }),
              request.routes.allSatisfy({ $0.coordinates.allSatisfy { CLLocationCoordinate2DIsValid($0.value) } }) else {
            throw RemotionError.resource("Invalid map camera, dimensions, or coordinates")
        }
        let job = Task { @MainActor in
            let options = MKMapSnapshotter.Options()
            options.mapType = switch request.mapStyle ?? .standard {
            case .standard: .standard
            case .muted: .mutedStandard
            case .satellite: .satellite
            case .hybrid: .hybrid
            }
            options.size = CGSize(width: request.width, height: request.height)
            let world = MKMapRect.world.size.width
            let center = MKMapPoint(request.center.value)
            let units = world / (256 * pow(2, request.zoom))
            options.mapRect = MKMapRect(x: center.x - Double(request.width) * units / 2,
                y: center.y - Double(request.height) * units / 2,
                width: Double(request.width) * units, height: Double(request.height) * units)
            let cameraKey = "\(request.center.latitude):\(request.center.longitude):\(request.zoom):\(request.width):\(request.height):\(request.mapStyle?.rawValue ?? "standard")"
            let snapshot: MKMapSnapshotter.Snapshot
            if let cached = cameraSnapshot, cached.key == cameraKey { snapshot = cached.value }
            else {
                let operation = MapOperation(MKMapSnapshotter(options: options))
                snapshot = try await withTaskCancellationHandler {
                    try await operation.snapshotter.start()
                } onCancel: { Task { @MainActor in operation.snapshotter.cancel() } }
                cameraSnapshot = (cameraKey, snapshot)
            }
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: request.width, pixelsHigh: request.height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else {
                throw RemotionError.rendering("Could not allocate map image")
            }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            snapshot.image.draw(in: NSRect(origin: .zero, size: options.size))
            // Keep the original attribution strip unobscured by user overlays.
            context.cgContext.saveGState()
            context.cgContext.clip(to: CGRect(x: 0, y: 24, width: request.width, height: max(0, request.height - 24)))
            for route in request.routes where route.coordinates.count > 1 {
                let path = NSBezierPath()
                path.lineWidth = max(0.5, route.width ?? 4)
                for (index, coordinate) in route.coordinates.enumerated() {
                    let point = snapshot.point(for: coordinate.value)
                    index == 0 ? path.move(to: point) : path.line(to: point)
                }
                Self.color(route.color, fallback: .systemBlue).setStroke(); path.stroke()
            }
            for marker in request.markers {
                let p = snapshot.point(for: marker.coordinate.value)
                let pin = NSBezierPath(ovalIn: NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
                Self.color(marker.color, fallback: .systemRed).setFill(); pin.fill()
                NSColor.white.setStroke(); pin.lineWidth = 2; pin.stroke()
                if let label = marker.label {
                    (label as NSString).draw(at: NSPoint(x: p.x + 9, y: p.y - 6),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
                }
            }
            context.cgContext.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            guard let image = rep.cgImage else { throw RemotionError.rendering("MapKit snapshot encoding failed") }
            let result = try await Self.png(image)
            func project(_ coordinate: RemotionCoordinate) -> CGPoint {
                let p = snapshot.point(for: coordinate.value)
                return CGPoint(x: p.x, y: Double(request.height) - p.y)
            }
            return RemotionMapSnapshot(png: result, markerPoints: request.markers.map { project($0.coordinate) },
                routePoints: request.routes.map { $0.coordinates.map(project) })
        }
        mapJobs[key] = job
        defer { mapJobs[key] = nil }
        let result = try await job.value
        // Keep camera reuse bounded; do not accumulate an entire movie in memory.
        if snapshots.values.reduce(0, { $0 + $1.png.count }) + result.png.count > 32 * 1024 * 1024 { snapshots.removeAll() }
        snapshots[key] = result
        return result
    }
    static func color(_ hex: String?, fallback: NSColor) -> NSColor {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return fallback }
        return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                       blue: Double(value & 255) / 255, alpha: 1)
    }
    func tile(_ path: String) async throws -> ResourceResponse {
        guard let config = configuration.openStreetMap, config.allowsExport,
              !config.attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemotionError.resource("Configure an export-permitted OpenStreetMap tile provider and attribution")
        }
        let parts = path.split(separator: "/").compactMap { Int($0) }
        guard config.minimumZoom >= 0, config.maximumZoom <= 22, config.minimumZoom <= config.maximumZoom,
              parts.count == 3, (config.minimumZoom...config.maximumZoom).contains(parts[0]),
              parts[1] >= 0, parts[2] >= 0, parts[1] < (1 << parts[0]), parts[2] < (1 << parts[0]) else {
            throw RemotionError.resource("Invalid tile coordinates")
        }
        var template = config.tileURL
        for (key, value) in zip(["z", "x", "y"], parts) { template = template.replacingOccurrences(of: "{\(key)}", with: "\(value)") }
        guard let url = URL(string: template), url.scheme == "https", let host = url.host,
              host != "tile.openstreetmap.org", !host.hasSuffix(".tile.openstreetmap.org") else {
            throw RemotionError.resource("Use an HTTPS tile provider that permits automated exports; public OSM tiles cannot be used")
        }
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: configuration.frameTimeout)
        request.allHTTPHeaderFields = config.headers
        request.setValue("RxRemotion/1.0 (macOS movie renderer)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count < 8 * 1024 * 1024 else {
            throw RemotionError.resource("The tile provider failed to return a map tile")
        }
        return ResourceResponse(type: response.mimeType ?? "image/png", data: data)
    }
    func cancel() {
        videoJobs.values.forEach { $0.cancel() }; videoJobs.removeAll(); videoTails.removeAll()
        videoFrames.removeAll(); videoFrameOrder.removeAll(); videoFrameBytes = 0
        generators.values.forEach { $0.cancelAllCGImageGeneration() }; generators.removeAll(); mapJobs.values.forEach { $0.cancel() }; mapJobs.removeAll(); snapshots.removeAll(); cameraSnapshot = nil }
}
