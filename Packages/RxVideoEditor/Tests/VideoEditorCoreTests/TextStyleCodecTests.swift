import Foundation
import Testing
@testable import VideoEditorCore

@Suite("Text style codec")
struct TextStyleCodecTests {
    @Test("A style saved before italic, alignment and outline existed decodes with defaults")
    func legacyDecodes() throws {
        let json = """
        {"fontName":"Avenir","fontSize":0.06,"colorHex":"#FFFF00","backgroundHex":"#000000","backgroundOpacity":0.4,"verticalPosition":0.8,"bold":false}
        """
        let style = try JSONDecoder().decode(TextStyle.self, from: Data(json.utf8))
        #expect(style.fontName == "Avenir")
        #expect(style.fontSize == 0.06)
        #expect(style.bold == false)
        #expect(style.italic == false)
        #expect(style.alignment == .center)
        #expect(style.strokeWidth == 0)
        #expect(style.strokeHex == "#000000")
    }

    @Test("Every field survives a round trip")
    func roundTrip() throws {
        let style = TextStyle(fontName: "Menlo", fontSize: 0.04, colorHex: "#FF0000", backgroundHex: "#00FF00", backgroundOpacity: 0.2,
                              verticalPosition: 0.1, bold: false, italic: true, alignment: .trailing, strokeWidth: 0.05, strokeHex: "#123456")
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(TextStyle.self, from: data) == style)
    }

    @Test("An empty object is the default caption style")
    func emptyIsDefault() throws {
        #expect(try JSONDecoder().decode(TextStyle.self, from: Data("{}".utf8)) == .caption)
    }
}
