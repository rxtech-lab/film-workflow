import Foundation

/// The authoring form as the backend describes it, from
/// `GET api/v1/admin/marketplace/form-schema`.
///
/// The website renders its admin form from the same description, so a field
/// added there shows up here without an app release. The app only decides
/// which control draws a field; what the fields are, what they accept and
/// which kinds they belong to is the server's to say.
///
/// Anything this build does not understand — a new field type, a kind added
/// after this release — is dropped rather than failing the whole payload.
nonisolated struct MarketplaceFormSchema: Decodable, Sendable {
    var version: Int
    var sections: [Section]
    var layouts: [KindLayout]

    enum CodingKeys: String, CodingKey { case version, sections, layouts }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sections = try container.decodeIfPresent([Lenient<Section>].self, forKey: .sections)?.compactMap(\.value) ?? []
        layouts = try container.decodeIfPresent([Lenient<KindLayout>].self, forKey: .layouts)?.compactMap(\.value) ?? []
    }

    func layout(for kind: MarketplaceKind) -> KindLayout? { layouts.first { $0.kind == kind } }

    /// The fields of `section` that belong to `kind`.
    func fields(_ section: Section, for kind: MarketplaceKind) -> [Field] {
        section.fields.filter { $0.applies(to: kind) }
    }

    struct Section: Decodable, Identifiable, Sendable {
        var id: String
        var title: String
        var help: String?
        var fields: [Field]

        enum CodingKeys: String, CodingKey { case id, title, help, fields }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            help = try container.decodeIfPresent(String.self, forKey: .help)
            fields = try container.decodeIfPresent([Lenient<Field>].self, forKey: .fields)?.compactMap(\.value) ?? []
        }
    }

    /// A field's id is the path into `MarketplaceItemInput` it edits, e.g.
    /// `metadata.fontFamily`. The editor maps it onto a binding.
    struct Field: Decodable, Identifiable, Sendable {
        var id: String
        var title: String
        var type: FieldType
        var required: Bool?
        var help: String?
        var placeholder: String?
        var maxLength: Int?
        var min: Double?
        var max: Double?
        /// Fixed choices for a `select`.
        var options: [Option]?
        /// Choices the app loads itself, currently only `categories`.
        var optionsSource: String?
        /// The kinds this field belongs to; nil means every kind.
        var kinds: [MarketplaceKind]?
        /// The files already match this value, so it cannot change once saved.
        var lockedWhenSaved: Bool?

        func applies(to kind: MarketplaceKind) -> Bool { kinds?.contains(kind) ?? true }

        enum CodingKeys: String, CodingKey {
            case id, title, type, required, help, placeholder, maxLength, min, max, options, optionsSource, kinds, lockedWhenSaved
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            type = try container.decode(FieldType.self, forKey: .type)
            required = try container.decodeIfPresent(Bool.self, forKey: .required)
            help = try container.decodeIfPresent(String.self, forKey: .help)
            placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
            maxLength = try container.decodeIfPresent(Int.self, forKey: .maxLength)
            min = try container.decodeIfPresent(Double.self, forKey: .min)
            max = try container.decodeIfPresent(Double.self, forKey: .max)
            options = try container.decodeIfPresent([Option].self, forKey: .options)
            optionsSource = try container.decodeIfPresent(String.self, forKey: .optionsSource)
            // A kind this build has never heard of simply does not match.
            kinds = try container.decodeIfPresent([Lenient<MarketplaceKind>].self, forKey: .kinds)?.compactMap(\.value)
            lockedWhenSaved = try container.decodeIfPresent(Bool.self, forKey: .lockedWhenSaved)
        }
    }

    /// Unknown cases throw so the field is dropped instead of drawn wrongly.
    enum FieldType: String, Decodable, Sendable {
        case text, multiline, number, tags, select, toggle
    }

    struct Option: Decodable, Hashable, Sendable {
        var value: String
        var label: String
    }

    /// What a kind needs beyond the shared fields: its files, the generators
    /// the app offers for it, and whether previews must use mock images.
    struct KindLayout: Decodable, Identifiable, Sendable {
        var kind: MarketplaceKind
        var label: String
        var content: ContentSlot
        var previewImage: FileSlot
        var previewVideo: FileSlot?
        var generators: [Generator]
        var filmAsset: Bool
        var mockPreview: Bool

        var id: MarketplaceKind { kind }

        enum CodingKeys: String, CodingKey { case kind, label, content, previewImage, previewVideo, generators, filmAsset, mockPreview }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(MarketplaceKind.self, forKey: .kind)
            label = try container.decode(String.self, forKey: .label)
            content = try container.decode(ContentSlot.self, forKey: .content)
            previewImage = try container.decode(FileSlot.self, forKey: .previewImage)
            previewVideo = try container.decodeIfPresent(FileSlot.self, forKey: .previewVideo)
            generators = try container.decodeIfPresent([Lenient<Generator>].self, forKey: .generators)?.compactMap(\.value) ?? []
            filmAsset = try container.decodeIfPresent(Bool.self, forKey: .filmAsset) ?? false
            mockPreview = try container.decodeIfPresent(Bool.self, forKey: .mockPreview) ?? false
        }
    }

    struct FileSlot: Decodable, Sendable {
        var role: String
        var title: String
        var hint: String
        var extensions: [String]
    }

    struct ContentSlot: Decodable, Sendable {
        var role: String
        var title: String
        var hint: String
        var extensions: [String]
        var editor: ContentEditor
    }

    /// How the content file is produced: uploaded, or edited inside the form
    /// as a template, a Core Image descriptor, or plain text.
    enum ContentEditor: String, Decodable, Sendable {
        case upload, descriptor, template, text
    }

    /// A generator the app can run for a kind.
    enum Generator: String, Decodable, Sendable {
        case video, music, image

        var title: String {
            switch self {
            case .video: return String(localized: "Generate Content…")
            case .music: return String(localized: "Generate Content…")
            case .image: return String(localized: "Generate Cover…")
            }
        }
    }
}
