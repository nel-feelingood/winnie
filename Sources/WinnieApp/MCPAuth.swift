import AppKit
import WinnieCore

/// Signs in to MCP servers that use OAuth, and hands out fresh tokens for requests.
///
/// A connector's Keychain secret is either a plain token the user pasted, or the JSON
/// credentials of an OAuth sign-in (access and refresh token, client id, endpoints).
@MainActor
final class MCPAuth: ObservableObject {
    enum Failure: LocalizedError {
        case notOAuth, noRegistration, rejected(String), network

        var errorDescription: String? {
            switch self {
            case .notOAuth: "Сервер не объявляет вход OAuth. Если ему нужен токен, вставь его вручную."
            case .noRegistration: "Сервер не поддерживает автоматическую регистрацию приложения. Нужен токен вручную."
            case .rejected(let message): "Сервер отказал: \(message)"
            case .network: "Не удалось связаться с сервером."
            }
        }
    }

    enum State { case signedIn, token, open }

    @Published private(set) var connecting: UUID?
    @Published private(set) var errors: [UUID: String] = [:]
    /// Bumped after a sign-in so rows re-read their state from the Keychain.
    @Published private(set) var revision = 0

    func state(of connector: AppConnector) -> State {
        guard Keychain.has(named: connector.secretName) else { return .open }
        return credentials(of: connector) == nil ? .token : .signedIn
    }

    // MARK: - Requests

    /// Enabled connectors with a currently valid token each; expired ones are refreshed first.
    func servers(for connectors: [AppConnector]) async -> [MCPServer] {
        var servers: [MCPServer] = []
        for connector in connectors where connector.isUsable {
            var token = Keychain.load(named: connector.secretName)
            if var stored = credentials(of: connector) {
                if stored.needsRefresh(), let renewed = try? await refresh(stored) {
                    stored = renewed
                    save(renewed, for: connector)
                }
                token = stored.accessToken
            }
            servers.append(MCPServer(name: connector.serverName, url: connector.url, token: token))
        }
        return servers
    }

    // MARK: - Sign-in

    func signIn(_ connector: AppConnector) {
        guard connecting == nil, let serverURL = URL(string: connector.url) else { return }
        connecting = connector.id
        errors[connector.id] = nil
        Task {
            do {
                let resource = try await discoverResource(serverURL)
                let server = try await discoverServer(resource.authorizationServer)
                guard let registration = server.registrationEndpoint else { throw Failure.noRegistration }

                let state = UUID().uuidString, verifier = GmailOAuth.makeVerifier()
                let redirect = try await LoopbackRedirect.start(expectedState: state)
                // Registered per sign-in: the loopback port differs every time and must match exactly.
                let clientID = try await register(at: registration, redirectURI: redirect.uri)
                guard let url = MCPOAuth.authorizationURL(endpoint: server.authorizationEndpoint, clientID: clientID,
                                                          redirectURI: redirect.uri,
                                                          scope: MCPOAuth.scope(resource: resource, server: server),
                                                          state: state, verifier: verifier, resource: resource.resource)
                else { throw Failure.network }
                NSWorkspace.shared.open(url)
                let code = try await redirect.waitForCode()

                let response = try await post(form: ["grant_type": "authorization_code", "code": code,
                                                     "redirect_uri": redirect.uri, "client_id": clientID,
                                                     "code_verifier": verifier, "resource": resource.resource],
                                              to: server.tokenEndpoint)
                guard let credentials = MCPOAuth.credentials(fromTokenResponse: response, clientID: clientID,
                                                             tokenEndpoint: server.tokenEndpoint, resource: resource.resource)
                else { throw Failure.rejected(Self.errorText(response)) }
                save(credentials, for: connector)
            } catch {
                errors[connector.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            connecting = nil
            revision += 1
        }
    }

    /// Whether the server advertises OAuth at all; used to decide between sign-in and a pasted token.
    func usesOAuth(_ serverURL: URL) async -> Bool {
        (try? await discoverResource(serverURL)) != nil
    }

    // MARK: - Steps

    private func discoverResource(_ serverURL: URL) async throws -> MCPOAuth.ResourceMetadata {
        for url in MCPOAuth.resourceMetadataURLs(for: serverURL) {
            if let data = try? await get(url), let metadata = MCPOAuth.resourceMetadata(from: data, serverURL: serverURL) {
                return metadata
            }
        }
        throw Failure.notOAuth
    }

    private func discoverServer(_ authorizationServer: String) async throws -> MCPOAuth.ServerMetadata {
        for url in MCPOAuth.serverMetadataURLs(for: authorizationServer) {
            if let data = try? await get(url), let metadata = MCPOAuth.serverMetadata(from: data) { return metadata }
        }
        throw Failure.notOAuth
    }

    private func register(at endpoint: String, redirectURI: String) async throws -> String {
        guard let url = URL(string: endpoint) else { throw Failure.network }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: MCPOAuth.registrationBody(redirectURI: redirectURI))
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let clientID = object?["client_id"] as? String else { throw Failure.rejected(Self.errorText(data)) }
        return clientID
    }

    private func refresh(_ stored: MCPOAuth.Credentials) async throws -> MCPOAuth.Credentials {
        guard let refreshToken = stored.refreshToken else { throw Failure.rejected("no refresh token") }
        let response = try await post(form: ["grant_type": "refresh_token", "refresh_token": refreshToken,
                                             "client_id": stored.clientID, "resource": stored.resource],
                                      to: stored.tokenEndpoint)
        guard let renewed = MCPOAuth.credentials(fromTokenResponse: response, clientID: stored.clientID,
                                                 tokenEndpoint: stored.tokenEndpoint, resource: stored.resource,
                                                 previous: stored)
        else { throw Failure.rejected(Self.errorText(response)) }
        return renewed
    }

    // MARK: - Plumbing

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.network }
        return data
    }

    private func post(form: [String: String], to endpoint: String) async throws -> Data {
        guard let url = URL(string: endpoint) else { throw Failure.network }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GmailOAuth.formBody(form)
        return try await URLSession.shared.data(for: request).0
    }

    private func credentials(of connector: AppConnector) -> MCPOAuth.Credentials? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MCPOAuth.Credentials.self, from: Data(Keychain.load(named: connector.secretName).utf8))
    }

    private func save(_ credentials: MCPOAuth.Credentials, for connector: AppConnector) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(credentials), let text = String(data: data, encoding: .utf8) else { return }
        Keychain.save(text, named: connector.secretName)
    }

    private static func errorText(_ data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return object?["error_description"] as? String ?? object?["error"] as? String ?? "неизвестная ошибка"
    }
}
