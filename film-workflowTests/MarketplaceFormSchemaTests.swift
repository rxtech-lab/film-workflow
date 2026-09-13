import Foundation
import Testing

@testable import film_workflow

/// The editor draws whatever `admin/marketplace/form-schema` describes, so
/// what matters here is that a payload from a newer backend still decodes:
/// the parts this build understands survive, the rest is dropped.
@Suite("Marketplace form schema")
struct MarketplaceFormSchemaTests {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private let json = """
    {"version":1,
     "sections":[{"id":"details","title":"Details","fields":[
       {"id":"kind","title":"Item type","type":"select","lockedWhenSaved":true,
        "options":[{"value":"footage","label":"Footage"},{"value":"font","label":"Font"}]},
       {"id":"categoryId","title":"Category","type":"select","optionsSource":"categories","required":true},
       {"id":"title","title":"Title","type":"text","maxLength":160},
       {"id":"pricePoints","title":"Price","type":"number","min":0,"max":1000000,"help":"Credits · 0 is free."},
       {"id":"metadata.fontFamily","title":"Font family","type":"text","kinds":["font"],"placeholder":"e.g. Inter"},
       {"id":"licence","title":"Licence","type":"signature"}]}],
     "layouts":[
       {"kind":"footage","label":"Footage",
        "content":{"role":"content","title":"Footage file","hint":"MP4 or MOV.","extensions":["mp4","mov"],"editor":"upload"},
        "previewImage":{"role":"preview-image","title":"Preview image","hint":"A frame.","extensions":["png"]},
        "previewVideo":{"role":"preview-video","title":"Preview video","hint":"Optional.","extensions":["mp4"]},
        "generators":["video","image","hologram"],"filmAsset":true,"mockPreview":false},
       {"kind":"project_template","label":"Project template",
        "content":{"role":"content","title":"Template","hint":"The shot plan.","extensions":["json"],"editor":"template"},
        "previewImage":{"role":"preview-image","title":"Preview image","hint":"Cover art.","extensions":["png"]},
        "previewVideo":null,"generators":["image"],"filmAsset":false,"mockPreview":true},
       {"kind":"hologram","label":"Holograms",
        "content":{"role":"content","title":"Hologram","hint":"","extensions":["obj"],"editor":"upload"},
        "previewImage":{"role":"preview-image","title":"Preview image","hint":"","extensions":["png"]},
        "previewVideo":null,"generators":[],"filmAsset":false,"mockPreview":false}]}
    """

    @Test("Fields, options and per-kind visibility come off the wire")
    func fields() throws {
        let schema = try decoder.decode(MarketplaceFormSchema.self, from: Data(json.utf8))
        let details = try #require(schema.sections.first)
        #expect(details.title == "Details")
        // The signature field is a type this build cannot draw, so it is dropped.
        #expect(details.fields.map(\.id) == ["kind", "categoryId", "title", "pricePoints", "metadata.fontFamily"])
        #expect(schema.fields(details, for: .font).map(\.id).contains("metadata.fontFamily"))
        #expect(!schema.fields(details, for: .audio).map(\.id).contains("metadata.fontFamily"))

        let kind = try #require(details.fields.first)
        #expect(kind.type == .select)
        #expect(kind.lockedWhenSaved == true)
        #expect(kind.options?.map(\.value) == ["footage", "font"])
        #expect(details.fields.first { $0.id == "categoryId" }?.optionsSource == "categories")
        #expect(details.fields.first { $0.id == "pricePoints" }?.help == "Credits · 0 is free.")
        #expect(details.fields.first { $0.id == "title" }?.maxLength == 160)
    }

    @Test("A kind's layout says how its content is made and what it can generate")
    func layouts() throws {
        let schema = try decoder.decode(MarketplaceFormSchema.self, from: Data(json.utf8))
        // A kind added after this release is dropped rather than failing the payload.
        #expect(schema.layouts.map(\.kind) == [.footage, .projectTemplate])

        let footage = try #require(schema.layout(for: .footage))
        #expect(footage.content.editor == .upload)
        #expect(footage.content.extensions == ["mp4", "mov"])
        #expect(footage.filmAsset)
        // "hologram" is not a generator this build knows, so it is left out.
        #expect(footage.generators == [.video, .image])
        #expect(footage.previewVideo?.title == "Preview video")

        let template = try #require(schema.layout(for: .projectTemplate))
        #expect(template.content.editor == .template)
        #expect(template.mockPreview)
        #expect(template.previewVideo == nil)
        #expect(schema.layout(for: .font) == nil)
    }
}
