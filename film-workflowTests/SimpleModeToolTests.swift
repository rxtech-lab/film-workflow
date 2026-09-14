import FilmTemplateKit
import Foundation
import JSONRenderUI
import SwiftData
import Testing

@testable import film_workflow

@Suite("Simple mode MCP tools")
@MainActor
struct SimpleModeToolTests {
    private func text(_ result: [String: Any]) throws -> String {
        let content = try #require(result["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }

    @Test("The wizard and web tools are published, with a film argument")
    func descriptors() {
        let tools = MCPToolRegistry.allDescriptors()
        let names = Set(tools.map(\.name))
        for expected in WizardTool.all + [WebTool.read] {
            #expect(names.contains(expected), "\(expected) is not published")
        }
        // Every tool but the two exceptions carries `film`; the routing test
        // asserts this globally, and these are new arrivals.
        for tool in tools where WizardTool.isWizardTool(tool.name) || tool.name == WebTool.read {
            let properties = tool.inputSchema["properties"] as? [String: Any]
            #expect(properties?["film"] != nil, "\(tool.name) lacks film")
        }
    }

    @Test("Wizard tools refuse a film that is not in a Simple mode run")
    func requiresSession() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleModeTools-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Plain")
            .appendingPathExtension("rxfilmstudio")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let document = try ProjectDocumentController.shared.createDocument(at: url)
        defer { Task { await ProjectDocumentController.shared.close(document) } }

        await #expect(throws: (any Error).self) {
            _ = try await MCPWizardHandlers.handle(
                name: WizardTool.reportProgress,
                arguments: ["message": "hello"],
                context: ModelContext(document.container)
            )
        }
    }

    @Test("Simple mode threads see the wizard tools; conversations do not")
    func toolScoping() {
        let conversation = AgentToolPolicy.toolNames(policy: .review, mode: .conversation)
        let wizard = AgentToolPolicy.toolNames(
            policy: .review,
            mode: .simpleMode(templateID: FilmTemplateCatalog.companyIntro.id)
        )

        for tool in WizardTool.all {
            #expect(!conversation.contains(tool), "\(tool) leaked into a conversation")
            #expect(wizard.contains(tool), "\(tool) missing from a wizard run")
        }
        #expect(wizard.contains(WebTool.read))
        #expect(wizard.contains("project_template_apply"))
        #expect(wizard.contains("sequence_add_clip"))

        // The wizard's surface is narrower, and never includes a destructive
        // tool no policy exposes.
        #expect(!wizard.contains("footage_delete"))
        #expect(!wizard.contains("sequence_render"))
        #expect(wizard.count < conversation.count)
    }

    @Test("The permission hook answers for the thread's own allowlist")
    func permissionsFollowMode() {
        let wizardMode = AgentThreadMode.simpleMode(templateID: "company-intro-video")
        #expect(AgentToolPolicy.allows(WizardTool.presentOptions, policy: .review, mode: wizardMode))
        #expect(!AgentToolPolicy.allows(WizardTool.presentOptions, policy: .review, mode: .conversation))
        #expect(!AgentToolPolicy.allows("footage_delete", policy: .direct, mode: wizardMode))
    }

    @Test("A thread's mode survives the round trip through its stored column")
    func threadMode() {
        let thread = AgentThread(title: "Wizard")
        #expect(thread.mode == .conversation)
        thread.mode = .simpleMode(templateID: "company-intro-video")
        #expect(thread.modeRaw == "simple:company-intro-video")
        #expect(thread.mode.templateID == "company-intro-video")
        // An older row has an empty column and must read as a conversation.
        thread.modeRaw = ""
        #expect(thread.mode == .conversation)
    }
}

@Suite("web_read")
@MainActor
struct WebReadTests {
    @Test("Only public http and https addresses are accepted")
    func addressFiltering() {
        #expect(MCPWebHandlers.validated("https://acme.com") != nil)
        #expect(MCPWebHandlers.validated("http://acme.com/about") != nil)

        // A tool the model can point anywhere must not reach the machine it
        // runs on, or the link-local metadata address.
        #expect(MCPWebHandlers.validated("http://localhost:3000") == nil)
        #expect(MCPWebHandlers.validated("http://127.0.0.1/") == nil)
        #expect(MCPWebHandlers.validated("http://192.168.1.5/admin") == nil)
        #expect(MCPWebHandlers.validated("http://169.254.169.254/latest/meta-data") == nil)
        #expect(MCPWebHandlers.validated("http://10.0.0.1") == nil)
        #expect(MCPWebHandlers.validated("http://172.20.0.1") == nil)
        #expect(MCPWebHandlers.validated("file:///etc/passwd") == nil)
        #expect(MCPWebHandlers.validated("not a url") == nil)
    }

    @Test("Ordinary public hostnames are not mistaken for private addresses")
    func hostnamesAreNotAddresses() {
        // Text matching would refuse these: "fd" reads as unique-local IPv6,
        // and the leading labels of the third read as RFC1918.
        for host in ["https://fda.gov", "https://fdic.gov", "https://fd.nl",
                     "https://192.168.1.1.example.com", "https://10.example.com"] {
            #expect(MCPWebHandlers.validated(host) != nil, "\(host) was refused")
        }
    }

    @Test("Address literals are recognised in their short and packed forms")
    func addressShorthands() {
        // `127.1` and `2130706433` both reach the loopback interface.
        #expect(MCPWebHandlers.isPrivateAddress("127.1"))
        #expect(MCPWebHandlers.isPrivateAddress("2130706433"))
        #expect(MCPWebHandlers.isPrivateAddress("::1"))
        #expect(MCPWebHandlers.isPrivateAddress("fc00::1"))
        #expect(MCPWebHandlers.isPrivateAddress("fe80::1"))
        #expect(MCPWebHandlers.isPrivateAddress("100.64.0.1"))
        #expect(MCPWebHandlers.isPrivateAddress("::ffff:127.0.0.1"))

        #expect(!MCPWebHandlers.isPrivateAddress("8.8.8.8"))
        #expect(!MCPWebHandlers.isPrivateAddress("acme.com"))
        #expect(!MCPWebHandlers.isPrivateAddress("2001:4860:4860::8888"))
    }

    @Test("A redirect onto a private host is refused, not followed")
    func redirectsAreRechecked() {
        // The guard runs on the same check as the original URL, off the main
        // actor. A public page redirecting to the metadata address must fail.
        #expect(MCPWebHandlers.validatedNonisolated("https://acme.com") != nil)
        #expect(MCPWebHandlers.validatedNonisolated("http://169.254.169.254/") == nil)
        #expect(MCPWebHandlers.validatedNonisolated("http://localhost/") == nil)
    }

    @Test("A page becomes title, description, text and images")
    func parsesPage() throws {
        let html = """
        <html><head>
          <title>Acme &amp; Co</title>
          <meta name="description" content="We make boots.">
          <meta property="og:image" content="/img/hero.jpg">
        </head><body>
          <script>var tracking = 1;</script>
          <style>body { color: red }</style>
          <h1>Built to last</h1>
          <p>Boots for people who walk.</p>
          <img src="https://cdn.acme.com/boot.png">
          <img src="/img/pixel.gif">
        </body></html>
        """
        let page = MCPWebHandlers.parse(html: html, base: URL(string: "https://acme.com")!)

        #expect(page.title == "Acme & Co")
        #expect(page.description == "We make boots.")
        #expect(page.text.contains("Built to last"))
        #expect(page.text.contains("Boots for people who walk."))
        // Script and style content is not page text.
        #expect(!page.text.contains("tracking"))
        #expect(!page.text.contains("color: red"))

        // Relative images become absolute; tracking pixels are dropped.
        #expect(page.images.contains("https://acme.com/img/hero.jpg"))
        #expect(page.images.contains("https://cdn.acme.com/boot.png"))
        #expect(!page.images.contains { $0.contains("pixel") })
    }
}
