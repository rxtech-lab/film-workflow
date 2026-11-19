import SwiftUI

public enum PreviewResolution: String, Sendable {
    public static let storageKey = "viewer.previewResolution"

    case standard
    case low

    public func scale(width: Int, height: Int) -> Double {
        let limit: Double = self == .low ? 640 : 1280
        let longest = Double(max(width, height, 1))
        let shortest = Double(max(min(width, height), 1))
        // Keep at least one pixel on the short edge for very narrow sources.
        return min(1, max(limit / longest, 1 / shortest))
    }
}

public struct PreviewResolutionPicker: View {
    @AppStorage(PreviewResolution.storageKey) private var resolution = PreviewResolution.standard

    public init() {}

    public var body: some View {
        Picker("Preview Resolution", selection: $resolution) {
            Text("Standard").tag(PreviewResolution.standard)
            Text("Low").tag(PreviewResolution.low)
        }
        .pickerStyle(.menu)
    }
}
