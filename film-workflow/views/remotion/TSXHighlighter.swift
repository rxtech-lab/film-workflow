#if os(macOS)
import AppKit
import Foundation
import SwiftUI

enum TSXHighlighter {
    static func highlight(_ source: String) -> AttributedString {
        var result = AttributedString(source)
        result.font = .system(.caption, design: .monospaced)
        result.foregroundColor = .primary

        guard let regex = Self.regex else { return result }

        let ns = source as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: source, range: full)

        for match in matches {
            for (name, color) in groups {
                let r = match.range(withName: name)
                if r.location != NSNotFound, r.length > 0 {
                    setColor(&result, source: source, range: r, color: Color(nsColor: color))
                    break
                }
            }
        }

        return result
    }

    /// Colors the text storage of an editable code view in place, keeping selection and undo.
    static func apply(to storage: NSTextStorage, font: NSFont) {
        let source = storage.string
        let full = NSRange(location: 0, length: (source as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)
        for match in regex?.matches(in: source, range: full) ?? [] {
            for (name, color) in groups {
                let range = match.range(withName: name)
                if range.location != NSNotFound, range.length > 0 {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                    break
                }
            }
        }
        storage.endEditing()
    }

    private static let groups: [(String, NSColor)] = [
        ("comment", .systemGray),
        ("string",  NSColor(red: 0.80, green: 0.30, blue: 0.30, alpha: 1)),
        ("jsxTag",  NSColor(red: 0.30, green: 0.50, blue: 0.85, alpha: 1)),
        ("keyword", NSColor(red: 0.62, green: 0.32, blue: 0.75, alpha: 1)),
        ("type",    NSColor(red: 0.20, green: 0.55, blue: 0.55, alpha: 1)),
        ("number",  NSColor(red: 0.85, green: 0.55, blue: 0.20, alpha: 1))
    ]

    private static let regex: NSRegularExpression? = {
        let pattern = [
            #"(?<comment>//[^\n]*|/\*[\s\S]*?\*/)"#,
            #"(?<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)"#,
            #"(?<jsxTag></?[A-Za-z][A-Za-z0-9]*)"#,
            #"(?<keyword>\b(?:import|export|from|as|default|const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|new|class|extends|implements|interface|type|enum|async|await|try|catch|finally|throw|typeof|instanceof|in|of|null|undefined|true|false|this|super|void|yield)\b)"#,
            #"(?<type>\b(?:string|number|boolean|any|unknown|never|object|symbol|bigint|React|FC|JSX)\b)"#,
            #"(?<number>\b\d+(?:\.\d+)?\b)"#
        ].joined(separator: "|")

        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    private static func setColor(_ attr: inout AttributedString, source: String, range nsRange: NSRange, color: Color) {
        guard let strRange = Range(nsRange, in: source) else { return }
        let lo = source.distance(from: source.startIndex, to: strRange.lowerBound)
        let hi = source.distance(from: source.startIndex, to: strRange.upperBound)
        guard lo < hi else { return }
        let chars = attr.characters
        let lower = chars.index(chars.startIndex, offsetBy: lo)
        let upper = chars.index(lower, offsetBy: hi - lo)
        attr[lower..<upper].foregroundColor = color
    }
}
#endif
