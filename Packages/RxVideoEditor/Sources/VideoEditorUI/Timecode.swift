import Foundation

/// `HH:MM:SS:FF` formatting for playheads and inspectors.
public enum Timecode {
    public static func string(seconds: TimeInterval, fps: Int) -> String {
        let fps = max(1, fps)
        let total = max(0, seconds)
        let wholeSeconds = Int(total)
        let frames = Int(((total - Double(wholeSeconds)) * Double(fps)).rounded(.down))
        let h = wholeSeconds / 3600
        let m = (wholeSeconds % 3600) / 60
        let s = wholeSeconds % 60
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, min(frames, fps - 1))
    }

    /// Parses `HH:MM:SS:FF`, `MM:SS:FF`, `SS:FF` or plain seconds.
    public static func seconds(from string: String, fps: Int) -> TimeInterval? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let plain = Double(trimmed) { return max(0, plain) }
        let parts = trimmed.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.map { $0! }
        var seconds = 0.0
        switch values.count {
        case 4: seconds = Double(values[0] * 3600 + values[1] * 60 + values[2]) + Double(values[3]) / Double(max(1, fps))
        case 3: seconds = Double(values[0] * 60 + values[1]) + Double(values[2]) / Double(max(1, fps))
        case 2: seconds = Double(values[0]) + Double(values[1]) / Double(max(1, fps))
        case 1: seconds = Double(values[0])
        default: return nil
        }
        return max(0, seconds)
    }
}
