import Foundation
import Testing
@testable import WinnieCore

@Suite struct ConnectorTests {
    @Test func serverNameIsAPlainIdentifier() {
        #expect(AppConnector(name: "Bridge App", url: "https://x").serverName == "bridge-app")
        #expect(AppConnector(name: "  My_CRM!! ", url: "https://x").serverName == "my-crm")
        // A name with no Latin letters still has to yield something usable.
        #expect(AppConnector(name: "Бридж", url: "https://x").serverName.hasPrefix("app-"))
    }

    @Test func onlyEnabledHttpsConnectorsAreUsable() {
        #expect(AppConnector(name: "A", url: "https://a.example/mcp").isUsable)
        #expect(!AppConnector(name: "A", url: "http://a.example/mcp").isUsable)
        #expect(!AppConnector(name: "A", url: "https://a.example/mcp", isEnabled: false).isUsable)
        #expect(!AppConnector(name: " ", url: "https://a.example/mcp").isUsable)
    }

    @Test func requestCarriesBothHalvesOfTheConnectorAndItsBeta() {
        let apps = [MCPServer(name: "bridge", url: "https://b.example/mcp", token: "tok"),
                    MCPServer(name: "open", url: "https://o.example/mcp", token: "")]
        let body = ClaudeClient.requestBody(model: .haiku, apps: apps, messages: [])

        let servers = body["mcp_servers"] as? [[String: Any]] ?? []
        #expect(servers.map { $0["name"] as? String } == ["bridge", "open"])
        #expect(servers[0]["authorization_token"] as? String == "tok")
        #expect(servers[1]["authorization_token"] == nil)

        let toolsets = (body["tools"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "mcp_toolset" }
        #expect(toolsets.map { $0["mcp_server_name"] as? String } == ["bridge", "open"])

        #expect(ClaudeClient.betas(model: .haiku, hasApps: true) == ["mcp-client-2025-11-20"])
        #expect(ClaudeClient.betas(model: .opus, hasApps: true).count == 2)
        #expect(ClaudeClient.betas(model: .haiku, hasApps: false).isEmpty)
    }

    @Test func withoutAppsTheRequestIsUnchanged() {
        let body = ClaudeClient.requestBody(model: .haiku, messages: [])
        #expect(body["mcp_servers"] == nil)
        #expect(!ClaudeClient.systemPrompt(master: "x").contains("Connected apps"))
        #expect(ClaudeClient.systemPrompt(master: "x", apps: ["bridge"]).contains("wait for Серёжа to confirm"))
    }

    @Test func appResultsCountAsUntrustedContent() {
        #expect(ClaudeClient.isUntrustedSource(["type": "mcp_tool_result"]))
    }
}
