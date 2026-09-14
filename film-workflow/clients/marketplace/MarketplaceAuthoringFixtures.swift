#if DEBUG
import Foundation

/// An in-memory HTTP boundary for native UI tests; never enabled in distributed builds.
@MainActor enum MarketplaceAuthoringFixtures {
    static func service() -> MarketplaceAuthoringService {
        let database = Database()
        return MarketplaceAuthoringService(root: FileManager.default.temporaryDirectory.appendingPathComponent("MarketplaceUITests-\(UUID().uuidString)"), authenticated: { true }) { path, method, data in
            try database.respond(path: path, method: method, data: data)
        }
    }
    /// The same shape the backend serves at `admin/marketplace/form-schema`.
    private static let formSchema: Data = {
        let options = MarketplaceKind.allCases.map { #"{"value":"\#($0.rawValue)","label":"\#($0.displayName)"}"# }.joined(separator: ",")
        let layouts = MarketplaceKind.allCases.map { kind -> String in
            let editor = switch kind {
            case .projectTemplate: "template"
            case .effect, .transition: "descriptor"
            default: "upload"
            }
            let content = #"{"role":"content","title":"Content","hint":"The file this item installs.","extensions":[],"editor":"\#(editor)"}"#
            let image = #"{"role":"preview-image","title":"Preview image","hint":"The still on the card.","extensions":["png"]}"#
            let video = #"{"role":"preview-video","title":"Preview video","hint":"A short demonstration.","extensions":["mp4"]}"#
            return #"{"kind":"\#(kind.rawValue)","label":"\#(kind.displayName)","content":\#(content),"previewImage":\#(image),"previewVideo":\#(video),"generators":["image"],"filmAsset":false,"mockPreview":\#(kind == .projectTemplate)}"#
        }.joined(separator: ",")
        let fields = [
            #"{"id":"kind","title":"Item type","type":"select","options":[\#(options)],"lockedWhenSaved":true}"#,
            #"{"id":"categoryId","title":"Category","type":"select","optionsSource":"categories"}"#,
            #"{"id":"title","title":"Title","type":"text"}"#,
            #"{"id":"description","title":"Description","type":"multiline"}"#,
            #"{"id":"pricePoints","title":"Price","type":"number","help":"Credits · 0 is free."}"#,
            #"{"id":"metadata.tags","title":"Tags","type":"tags"}"#,
        ].joined(separator: ",")
        return Data(#"{"version":1,"sections":[{"id":"details","title":"Details","fields":[\#(fields)]}],"layouts":[\#(layouts)]}"#.utf8)
    }()

    private final class Database {
        var categories = MarketplaceKind.allCases.map { MarketplaceCategory(id: UUID().uuidString, kind: $0, slug: "general", name: "General") }
        var items: [String: MarketplaceAuthoringItem] = [:]
        func respond(path: String, method: String, data: Data?) throws -> Data {
            func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
            if path == "capabilities" { return Data(#"{"can_author":true,"user_id":"ui-test-admin"}"#.utf8) }
            if path == "form-schema", method == "GET" { return MarketplaceAuthoringFixtures.formSchema }
            if path == "categories", method == "GET" { return try encode(["categories": categories]) }
            if path == "categories", method == "POST", let data {
                struct Input: Decodable { var kind: MarketplaceKind; var name: String; var icon: String? }
                let input = try JSONDecoder().decode(Input.self, from: data)
                let category = MarketplaceCategory(id: UUID().uuidString, kind: input.kind, slug: input.name.lowercased(), name: input.name, icon: input.icon)
                categories.append(category)
                return try encode(["category": category])
            }
            if path.hasPrefix("categories/"), method == "PATCH", let data {
                struct Input: Decodable { var name: String; var icon: String? }
                let input = try JSONDecoder().decode(Input.self, from: data)
                let id = String(path.dropFirst("categories/".count))
                guard let index = categories.firstIndex(where: { $0.id == id }) else { throw MarketplaceAuthoringError.invalid("Fixture category not found.") }
                categories[index].name = input.name; categories[index].icon = input.icon
                return try encode(["category": categories[index]])
            }
            if path.hasPrefix("items?"), method == "GET" { return try encode(MarketplaceAuthoringPage(items: Array(items.values), page: 1, pageCount: 1, total: items.count)) }
            if path == "items", method == "POST", let data {
                let input = try JSONDecoder().decode(MarketplaceItemInput.self, from: data)
                let id = input.draftId ?? UUID().uuidString
                if items[id] == nil { items[id] = .init(item: MarketplaceItem(id: id, kind: input.kind, category: "general", title: input.title, description: input.description, pricePoints: input.pricePoints), categoryId: input.categoryId, status: "draft", updatedAt: "1") }
                struct Created: Encodable { var ok = true; var id: String }; return try encode(Created(id: id))
            }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 2, var value = items[parts[1]] else { throw MarketplaceAuthoringError.invalid("Fixture item not found.") }
            if method == "DELETE", parts.count == 2 { items[parts[1]] = nil; return Data(#"{"ok":true}"#.utf8) }
            if method == "PATCH", let data {
                let input = try JSONDecoder().decode(MarketplaceItemInput.self, from: data)
                value.item = MarketplaceItem(id: value.id, kind: input.kind, category: "general", title: input.title, description: input.description, pricePoints: input.pricePoints)
                value.categoryId = input.categoryId
            }
            if method == "PUT", let data {
                let input = try JSONDecoder().decode([String: String].self, from: data)
                value.contentText = input["text"]
            }
            if parts.last == "publish", let data {
                let input = try JSONDecoder().decode([String: Bool].self, from: data)
                if input["published"] == true, value.item.kind == .projectTemplate { throw MarketplaceAuthoringError.invalid("Templates need a cover and a preview made with mock images.") }
                value.status = input["published"] == true ? "published" : "draft"
            }
            items[value.id] = value
            return method == "GET" ? try encode(value) : Data(#"{"ok":true}"#.utf8)
        }
    }
}
#endif
