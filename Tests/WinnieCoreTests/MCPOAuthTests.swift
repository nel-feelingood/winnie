import Foundation
import Testing
@testable import WinnieCore

@Suite struct MCPOAuthTests {
    let server = URL(string: "https://mcp.example.ai/mcp")!

    @Test func looksForPathSpecificMetadataFirst() {
        #expect(MCPOAuth.resourceMetadataURLs(for: server).map(\.absoluteString) == [
            "https://mcp.example.ai/.well-known/oauth-protected-resource/mcp",
            "https://mcp.example.ai/.well-known/oauth-protected-resource",
        ])
        #expect(MCPOAuth.resourceMetadataURLs(for: URL(string: "https://mcp.example.ai/")!).count == 1)
        #expect(MCPOAuth.serverMetadataURLs(for: "https://auth.example.ai/").first?.absoluteString
            == "https://auth.example.ai/.well-known/oauth-authorization-server")
    }

    @Test func parsesMetadataAndBuildsTheScope() throws {
        let resource = try #require(MCPOAuth.resourceMetadata(from: Data(#"""
        {"authorization_servers":["https://auth.example.ai"],"resource":"https://mcp.example.ai/mcp","scopes_supported":["app:mcp"]}
        """#.utf8), serverURL: server))
        let metadata = try #require(MCPOAuth.serverMetadata(from: Data(#"""
        {"authorization_endpoint":"https://auth.example.ai/authorize","token_endpoint":"https://auth.example.ai/token",
         "registration_endpoint":"https://auth.example.ai/register","scopes_supported":["app:mcp","offline_access"]}
        """#.utf8)))
        #expect(resource.authorizationServer == "https://auth.example.ai")
        #expect(metadata.registrationEndpoint == "https://auth.example.ai/register")
        #expect(MCPOAuth.scope(resource: resource, server: metadata) == "app:mcp offline_access")
        #expect(MCPOAuth.resourceMetadata(from: Data("{}".utf8), serverURL: server) == nil)
    }

    @Test func authorizationURLCarriesPKCEAndTheResource() throws {
        let url = try #require(MCPOAuth.authorizationURL(endpoint: "https://auth.example.ai/authorize", clientID: "c1",
                                                         redirectURI: "http://127.0.0.1:5123", scope: "app:mcp",
                                                         state: "s", verifier: "v", resource: "https://mcp.example.ai/mcp"))
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["resource"] == "https://mcp.example.ai/mcp")
        #expect(items["client_id"] == "c1" && items["scope"] == "app:mcp")
    }

    @Test func registersAsAPublicClient() {
        let body = MCPOAuth.registrationBody(redirectURI: "http://127.0.0.1:5123")
        #expect(body["token_endpoint_auth_method"] as? String == "none")
        #expect(body["redirect_uris"] as? [String] == ["http://127.0.0.1:5123"])
    }

    @Test func refreshKeepsTheOldRefreshTokenWhenNoneIsReturned() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try #require(MCPOAuth.credentials(fromTokenResponse: Data(#"{"access_token":"a1","refresh_token":"r1","expires_in":3600}"#.utf8),
                                                      clientID: "c", tokenEndpoint: "t", resource: "r", now: now))
        #expect(!first.needsRefresh(at: now) && first.needsRefresh(at: now.addingTimeInterval(3550)))
        let renewed = try #require(MCPOAuth.credentials(fromTokenResponse: Data(#"{"access_token":"a2","expires_in":3600}"#.utf8),
                                                        clientID: "c", tokenEndpoint: "t", resource: "r", previous: first, now: now))
        #expect(renewed.accessToken == "a2" && renewed.refreshToken == "r1")
        #expect(MCPOAuth.credentials(fromTokenResponse: Data(#"{"error":"invalid_grant"}"#.utf8), clientID: "c", tokenEndpoint: "t", resource: "r") == nil)
    }
}
