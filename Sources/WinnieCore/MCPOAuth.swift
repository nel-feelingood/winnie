import Foundation

/// OAuth for MCP servers, following the MCP authorization spec: protected-resource
/// metadata → authorization-server metadata → dynamic client registration →
/// authorization code with PKCE → refresh tokens. Pure helpers; the networking and
/// the browser round trip live in the app.
public enum MCPOAuth {
    public struct ResourceMetadata: Equatable, Sendable {
        public var resource: String
        public var authorizationServer: String
        public var scopes: [String]
    }

    public struct ServerMetadata: Equatable, Sendable {
        public var authorizationEndpoint: String
        public var tokenEndpoint: String
        public var registrationEndpoint: String?
        public var scopes: [String]
    }

    /// What is stored in the Keychain for an OAuth-connected server.
    public struct Credentials: Codable, Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date
        public var clientID: String
        public var tokenEndpoint: String
        public var resource: String

        public init(accessToken: String, refreshToken: String?, expiresAt: Date, clientID: String,
                    tokenEndpoint: String, resource: String) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.clientID = clientID
            self.tokenEndpoint = tokenEndpoint
            self.resource = resource
        }

        public func needsRefresh(at now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) < 120 }
    }

    /// Where a server may publish its protected-resource metadata: the path-specific
    /// document first, then the host-wide one.
    public static func resourceMetadataURLs(for serverURL: URL) -> [URL] {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return [] }
        let path = components.path == "/" ? "" : components.path
        components.query = nil
        return ["/.well-known/oauth-protected-resource" + path, "/.well-known/oauth-protected-resource"].compactMap {
            components.path = $0
            return components.url
        }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    public static func serverMetadataURLs(for authorizationServer: String) -> [URL] {
        let base = authorizationServer.hasSuffix("/") ? String(authorizationServer.dropLast()) : authorizationServer
        return ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"].compactMap { URL(string: base + $0) }
    }

    public static func resourceMetadata(from data: Data, serverURL: URL) -> ResourceMetadata? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = (object["authorization_servers"] as? [String])?.first else { return nil }
        return ResourceMetadata(resource: object["resource"] as? String ?? serverURL.absoluteString,
                                authorizationServer: server, scopes: object["scopes_supported"] as? [String] ?? [])
    }

    public static func serverMetadata(from data: Data) -> ServerMetadata? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authorize = object["authorization_endpoint"] as? String,
              let token = object["token_endpoint"] as? String else { return nil }
        return ServerMetadata(authorizationEndpoint: authorize, tokenEndpoint: token,
                              registrationEndpoint: object["registration_endpoint"] as? String,
                              scopes: object["scopes_supported"] as? [String] ?? [])
    }

    /// The resource's own scopes, plus `offline_access` when offered: without it many
    /// servers issue no refresh token and the sign-in would last an hour.
    public static func scope(resource: ResourceMetadata, server: ServerMetadata) -> String {
        var scopes = resource.scopes
        if server.scopes.contains("offline_access"), !scopes.contains("offline_access") { scopes.append("offline_access") }
        return scopes.joined(separator: " ")
    }

    /// A public client (no secret): Winnie is a desktop app and could not keep one.
    public static func registrationBody(redirectURI: String) -> [String: Any] {
        ["client_name": "Winnie", "redirect_uris": [redirectURI], "grant_types": ["authorization_code", "refresh_token"],
         "response_types": ["code"], "token_endpoint_auth_method": "none"]
    }

    public static func authorizationURL(endpoint: String, clientID: String, redirectURI: String, scope: String,
                                        state: String, verifier: String, resource: String) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: GmailOAuth.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Binds the token to this MCP server, as the MCP spec requires.
            URLQueryItem(name: "resource", value: resource),
        ] + (scope.isEmpty ? [] : [URLQueryItem(name: "scope", value: scope)])
        return components.url
    }

    /// Merges a token response into credentials; a refresh may omit the refresh token, in which case the old one stays.
    public static func credentials(fromTokenResponse data: Data, clientID: String, tokenEndpoint: String, resource: String,
                                   previous: Credentials? = nil, now: Date = Date()) -> Credentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String else { return nil }
        let lifetime = (object["expires_in"] as? Double) ?? Double(object["expires_in"] as? Int ?? 3600)
        return Credentials(accessToken: access, refreshToken: object["refresh_token"] as? String ?? previous?.refreshToken,
                           expiresAt: now.addingTimeInterval(lifetime), clientID: clientID,
                           tokenEndpoint: tokenEndpoint, resource: resource)
    }
}
