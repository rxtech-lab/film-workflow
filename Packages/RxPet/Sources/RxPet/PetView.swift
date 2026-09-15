import AppKit
import SwiftUI

@MainActor public struct PetView: View {
    private var character: PetCharacter
    private var state: PetState
    private var side: CGFloat = 72
    private var animate = true
    private var selectedFrame: Int?
    private var playbackSpeed: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var animationStart = Date()
    public init(character: PetCharacter = .cameraBuddy, state: PetState = PetState()) { self.character = character; self.state = state }
    public func mood(_ value: PetMood) -> Self { var copy = self; copy.state.mood = value; return copy }
    public func status(_ value: PetStatus) -> Self { var copy = self; copy.state.status = value; return copy }
    public func motion(_ value: PetMotion) -> Self { var copy = self; copy.state.motion = value; return copy }
    public func message(_ value: String?) -> Self { var copy = self; copy.state.message = value; return copy }
    public func size(_ value: CGFloat) -> Self { var copy = self; copy.side = max(24, value); return copy }
    /// Select a still frame for design previews and snapshot inspection.
    public func animationFrame(_ index: Int?) -> Self { var copy = self; copy.selectedFrame = index.map { max(0, $0) }; return copy }
    public func animated(_ value: Bool) -> Self { var copy = self; copy.animate = value; return copy }
    /// Multiplies the artwork's timing; 0.5 plays at half speed.
    public func animationSpeed(_ value: Double) -> Self { var copy = self; copy.playbackSpeed = value.isFinite ? min(4, max(0.1, value)) : 1; return copy }
    public var body: some View {
        let durations = PetSpriteCache.durations(character, row: state.resolvedMotion.atlasRow)
        VStack(spacing: 3) {
            if let message = state.message, !message.isEmpty {
                Text(message).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 9).padding(.vertical, 5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .frame(maxWidth: 190)
            }
            TimelineView(.animation(minimumInterval: (durations.min() ?? 0.25) / playbackSpeed, paused: reduceMotion || !animate || !visible || selectedFrame != nil)) { timeline in
                let frame = selectedFrame.map { $0 % character.columns } ?? (reduceMotion || !animate ? 0 : PetSpriteCache.frameIndex(elapsed: timeline.date.timeIntervalSince(animationStart) * playbackSpeed, durations: durations))
                if let image = PetSpriteCache.frame(character, row: state.resolvedMotion.atlasRow, column: frame, mood: state.status == .idle && state.mood == nil ? nil : state.resolvedMood) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.none).scaledToFit()
                }
            }.frame(width: side, height: side)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera companion, \(state.status.rawValue). \(state.message ?? "")")
        .onAppear { animationStart = Date(); visible = true }.onDisappear { visible = false }
        .onChange(of: state.resolvedMotion) { animationStart = Date() }
    }
}

struct PetAnimationManifest: Decodable {
    struct Frame: Decodable { let x: Int; let y: Int; let width: Int; let height: Int; let faceX: Double; let faceY: Double; let faceSize: Double; let duration: Double }
    let version: Int; let frameWidth: Int; let frameHeight: Int; let frames: [Frame]
}

@MainActor enum PetSpriteCache {
    private static var frames: [String: CGImage] = [:]
    private static var images: [URL: CGImage] = [:]
    private static var manifests: [URL: PetAnimationManifest] = [:]
    private static func manifest(_ character: PetCharacter) -> PetAnimationManifest? {
        guard let url = character.manifestURL else { return nil }
        if manifests[url] == nil, let data = try? Data(contentsOf: url) { manifests[url] = try? JSONDecoder().decode(PetAnimationManifest.self, from: data) }
        return manifests[url]
    }
    static func durations(_ character: PetCharacter, row: Int) -> [Double] {
        let frames = manifest(character)?.frames ?? []
        return (0..<character.columns).map { column in
            let index = min(row, character.rows - 1) * character.columns + column
            let duration = frames.indices.contains(index) ? frames[index].duration : 1 / character.framesPerSecond
            return duration.isFinite && duration > 0 ? duration : 0.25
        }
    }
    static func frameIndex(elapsed: Double, durations: [Double]) -> Int {
        let total = durations.reduce(0, +)
        guard total > 0, elapsed.isFinite else { return 0 }
        var remaining = max(0, elapsed).truncatingRemainder(dividingBy: total)
        for (index, duration) in durations.enumerated() {
            if remaining < duration { return index }; remaining -= duration
        }
        return 0
    }
    private static func image(_ url: URL) -> CGImage? {
        if let image = images[url] { return image }
        let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        images[url] = image; return image
    }
    static func frame(_ character: PetCharacter, row: Int, column: Int, mood: PetMood? = nil) -> CGImage? {
        let key = "\(character.atlasURL.path):\(row):\(column):\(mood?.rawValue ?? "original")"
        if let cached = frames[key] { return cached }
        guard let source = image(character.atlasURL) else { return nil }
        let manifest = manifest(character)
        let index = min(row, character.rows - 1) * character.columns + column
        if let manifest, manifest.frames.indices.contains(index) {
            let frame = manifest.frames[index]
            guard let sprite = source.cropping(to: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)),
                  let context = CGContext(data: nil, width: manifest.frameWidth, height: manifest.frameHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .none
            let ox = Double(manifest.frameWidth - frame.width) / 2, oy = Double(manifest.frameHeight - frame.height) / 2
            context.draw(sprite, in: CGRect(x: ox, y: oy, width: Double(frame.width), height: Double(frame.height)))
            if let mood, let url = character.expressionsURL, let expressions = image(url), let column = PetMood.allCases.firstIndex(of: mood) {
                let side = expressions.width / PetMood.allCases.count
                if let face = expressions.cropping(to: CGRect(x: column * side, y: (expressions.height - side) / 2, width: side, height: side)) {
                    context.setFillColor(CGColor(red: 0.015, green: 0.025, blue: 0.095, alpha: 1))
                    context.fillEllipse(in: CGRect(x: ox + frame.faceX - 21, y: oy + Double(frame.height) - frame.faceY - 21, width: 42, height: 42))
                    context.draw(face, in: CGRect(x: ox + frame.faceX - frame.faceSize / 2, y: oy + Double(frame.height) - frame.faceY - frame.faceSize / 2, width: frame.faceSize, height: frame.faceSize))
                }
            }
            let rendered = context.makeImage(); frames[key] = rendered; return rendered
        }
        let width = Double(source.width) / Double(character.columns), height = Double(source.height) / Double(character.rows)
        let rect = CGRect(x: Double(column) * width, y: Double(min(row, character.rows - 1)) * height, width: width, height: height).integral
        guard let frame = source.cropping(to: rect) else { return nil }; frames[key] = frame; return frame
    }
}
