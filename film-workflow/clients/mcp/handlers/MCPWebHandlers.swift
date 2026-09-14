import AppKit
import FilmTemplateKit
import Foundation

/// Reading a public web page.
///
/// The coding agents' own `WebFetch` is withheld from every thread and only
/// exists on the CLI engines anyway, so a wizard that has to read the user's
/// company website brings its own tool. Being an MCP tool, all five engines can
/// call it and the same limits apply to each.
@MainActor
enum MCPWebHandlers {
    static let defaultMaxCharacters = 20_000
    static let maxCharacters = 60_000
    /// Past this, the AppKit HTML parser costs more than the page is worth.
    static let attributedStringLimit = 1_000_000
    static let maxBodyBytes = 5_000_000
    static let timeout: TimeInterval = 15

    static let descriptors: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: WebTool.read,
            description: "Read a public web page as text. Returns the page title, its meta description, the visible text and any large images it advertises. Use this to learn about a company from its website. http and https only; private and loopback addresses are refused.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The page to read, e.g. https://example.com."] as [String: Any],
                    "max_chars": [
                        "type": "integer",
                        "description": "How much text to return. Defaults to \(defaultMaxCharacters), capped at \(maxCharacters).",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["url"],
            ]
        ),
    ]

    static func canHandle(_ name: String) -> Bool { name == WebTool.read }

    static func handle(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard name == WebTool.read else {
            throw MCPToolError.invalidArguments("unknown tool: \(name)")
        }
        guard let raw = arguments["url"] as? String, let url = validated(raw) else {
            throw MCPToolError.invalidArguments("url must be an http or https address on the public internet")
        }
        let limit = min(
            max(500, (arguments["max_chars"] as? Int) ?? defaultMaxCharacters),
            maxCharacters
        )

        var request = URLRequest(url: url, timeoutInterval: timeout)
        // Some sites serve a blank shell to an unknown client; identify as a
        // normal browser-like reader rather than being refused outright.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 RxFilmStudio/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        // Streamed rather than `data(for:)`: that buffers the whole response
        // before anything can be truncated, so one endless page would grow the
        // app's memory without limit.
        let (stream, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MCPToolError.invalidArguments("\(url.absoluteString) returned HTTP \(http.statusCode)")
        }
        var body = Data()
        body.reserveCapacity(min(maxBodyBytes, 1 << 18))
        var hitCap = false
        for try await byte in stream {
            body.append(byte)
            if body.count >= maxBodyBytes { hitCap = true; break }
        }

        let html = String(data: body, encoding: .utf8)
            ?? String(data: body, encoding: .isoLatin1)
            ?? ""

        let page = parse(html: html, base: response.url ?? url)
        let truncated = page.text.count > limit || hitCap
        return MCPToolRegistry.jsonResult([
            "url": url.absoluteString,
            "final_url": (response.url ?? url).absoluteString,
            "title": page.title as Any,
            "description": page.description as Any,
            "text": String(page.text.prefix(limit)),
            "images": page.images,
            "truncated": truncated,
        ] as [String: Any])
    }

    /// A session that re-checks every redirect.
    ///
    /// Validating only the URL the model passed would be a hole: a public
    /// address is free to redirect to `127.0.0.1` or the link-local metadata
    /// address, and the request would follow it.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: RedirectGuard(),
            delegateQueue: nil
        )
    }()

    /// Refuses a redirect that leaves the public internet.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url,
                  MCPWebHandlers.validatedNonisolated(url.absoluteString) != nil
            else {
                // Passing nil stops here and returns the redirect itself, which
                // the caller reports as a non-2xx.
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    // MARK: - Address checks

    /// Only public http(s). A tool the model can aim anywhere should not be
    /// able to reach the loopback interface or the link-local metadata address.
    static func validated(_ raw: String) -> URL? { validatedNonisolated(raw) }

    nonisolated static func validatedNonisolated(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(),
              !host.isEmpty
        else { return nil }

        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return nil
        }
        if isPrivateAddress(host) { return nil }
        return url
    }

    /// Whether `host` is a literal address outside the public internet.
    ///
    /// Only literals: a name is left to DNS. Matching on text alone would
    /// refuse `fda.gov` as a unique-local IPv6 address, and
    /// `192.168.1.1.example.com` — a perfectly ordinary public name — as
    /// RFC1918.
    nonisolated static func isPrivateAddress(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host

        if let parts = ipv4Octets(bare) {
            switch (parts[0], parts[1]) {
            case (0, _), (10, _), (127, _): return true
            case (169, 254): return true
            case (172, 16...31): return true
            case (192, 168): return true
            case (100, 64...127): return true
            default: return false
            }
        }

        // An IPv6 literal, or one of the decimal/short forms that `inet_pton`
        // and URLSession both accept but a dotted-quad check would miss
        // (`127.1`, `2130706433`).
        if bare.contains(":") {
            let lower = bare.lowercased()
            if lower == "::1" || lower == "::" { return true }
            // fc00::/7 is unique-local; fe80::/10 link-local.
            if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }
            if lower.hasPrefix("fe8") || lower.hasPrefix("fe9")
                || lower.hasPrefix("fea") || lower.hasPrefix("feb") { return true }
            // A v6-mapped v4 address is still that v4 address.
            if let mapped = lower.split(separator: ":").last.map(String.init),
               let parts = ipv4Octets(mapped) {
                return isPrivateAddress("\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3])")
            }
            return false
        }

        if let packed = packedIPv4(bare) {
            return isPrivateAddress(
                "\(packed >> 24 & 0xFF).\(packed >> 16 & 0xFF).\(packed >> 8 & 0xFF).\(packed & 0xFF)"
            )
        }
        return false
    }

    /// The four octets of a dotted-quad literal, or nil when `host` is a name.
    private nonisolated static func ipv4Octets(_ host: String) -> [UInt8]? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return nil }
        let octets = labels.compactMap { UInt8($0) }
        // Every label has to be numeric; `192.168.1.1.example.com` splits into
        // six and `a.b.c.d` yields none.
        return octets.count == 4 ? octets : nil
    }

    /// `127.1` and `2130706433` are addresses too. Returns the packed value.
    private nonisolated static func packedIPv4(_ host: String) -> UInt32? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(labels.count) else { return nil }
        let numbers = labels.compactMap { UInt32($0) }
        guard numbers.count == labels.count else { return nil }

        switch numbers.count {
        case 1:
            return numbers[0]
        case 2:
            guard numbers[0] <= 0xFF, numbers[1] <= 0xFF_FFFF else { return nil }
            return numbers[0] << 24 | numbers[1]
        default:
            guard numbers[0] <= 0xFF, numbers[1] <= 0xFF, numbers[2] <= 0xFFFF else { return nil }
            return numbers[0] << 24 | numbers[1] << 16 | numbers[2]
        }
    }

    // MARK: - HTML

    struct Page {
        var title: String?
        var description: String?
        var text: String
        var images: [String]
    }

    static func parse(html: String, base: URL) -> Page {
        Page(
            title: firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: html).map(decodeEntities),
            description: metaContent(name: "description", in: html)
                ?? metaContent(property: "og:description", in: html),
            text: text(from: html),
            images: images(in: html, base: base)
        )
    }

    /// Visible text. `NSAttributedString` gives the better reading order, but it
    /// has to run on the main thread and is slow on a big page, so anything
    /// large falls back to stripping tags.
    static func text(from html: String) -> String {
        let stripped = strippingScripts(html)
        if stripped.utf8.count <= attributedStringLimit,
           let data = stripped.data(using: .utf8),
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html,
                         .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil
           ) {
            return collapse(attributed.string)
        }
        return collapse(decodeEntities(
            stripped.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        ))
    }

    static func strippingScripts(_ html: String) -> String {
        var output = html
        for tag in ["script", "style", "noscript", "svg", "template"] {
            output = output.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return output
    }

    static func collapse(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t\\x{00A0}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n[ \\t]*\\n[\\s]*", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func metaContent(name: String, in html: String) -> String? {
        firstMatch(
            "<meta[^>]+name=[\"']\(name)[\"'][^>]+content=[\"']([^\"']*)[\"']",
            in: html
        ).map(decodeEntities)
    }

    static func metaContent(property: String, in html: String) -> String? {
        firstMatch(
            "<meta[^>]+property=[\"']\(property)[\"'][^>]+content=[\"']([^\"']*)[\"']",
            in: html
        ).map(decodeEntities)
    }

    /// Images worth showing on a card: the social preview first, then whatever
    /// the page links, absolute and de-duplicated.
    static func images(in html: String, base: URL, limit: Int = 10) -> [String] {
        var found: [String] = []
        if let og = metaContent(property: "og:image", in: html) { found.append(og) }
        found.append(contentsOf: allMatches(#"<img[^>]+src=["']([^"']+)["']"#, in: html))

        var seen: Set<String> = []
        var absolute: [String] = []
        for candidate in found {
            guard let url = URL(string: candidate, relativeTo: base)?.absoluteURL,
                  url.scheme == "http" || url.scheme == "https"
            else { continue }
            // Tracking pixels and inline icons are noise on an option card.
            let path = url.path.lowercased()
            guard !path.hasSuffix(".svg"), !path.contains("pixel"), !path.contains("sprite") else { continue }
            let text = url.absoluteString
            if seen.insert(text).inserted { absolute.append(text) }
            if absolute.count >= limit { break }
        }
        return absolute
    }

    static func decodeEntities(_ text: String) -> String {
        var output = text
        let entities = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&mdash;", "—"),
            ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "'"), ("&lsquo;", "'"),
        ]
        for (entity, replacement) in entities {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[captured])
        }
    }
}
