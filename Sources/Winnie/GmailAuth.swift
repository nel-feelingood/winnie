import AppKit
import Network
import WinnieCore

/// Signs in to Google with the user's own OAuth client and keeps the tokens.
///
/// Installed-app flow: the consent page opens in the system browser, and Google redirects
/// to a one-shot listener on the loopback interface. Only the refresh token is stored
/// (in the Keychain); access tokens live in memory and are renewed on demand.
@MainActor
final class GmailAuth: ObservableObject {
    enum Failure: LocalizedError {
        case missingClient, cancelled, listener, token(String)

        var errorDescription: String? {
            switch self {
            case .missingClient: "Сначала вставь Client ID и Client secret."
            case .cancelled: "Вход не завершён."
            case .listener: "Не удалось принять ответ от Google."
            case .token(let message): "Google отказал: \(message)"
            }
        }
    }

    @Published private(set) var address: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var lastError: String?

    var isConnected: Bool { Keychain.has(.googleRefreshToken) }

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast

    init() {
        address = UserDefaults.standard.string(forKey: "gmailAddress")
    }

    var client: GmailClient {
        GmailClient { [weak self] in
            guard let self else { throw GmailError.notConnected }
            return try await self.validAccessToken()
        }
    }

    // MARK: - Connect / disconnect

    func connect(clientID: String, clientSecret: String) {
        guard !clientID.isEmpty, !clientSecret.isEmpty else { return lastError = Failure.missingClient.errorDescription }
        Keychain.save(clientID, for: .googleClientID)
        Keychain.save(clientSecret, for: .googleClientSecret)
        isConnecting = true
        lastError = nil
        Task {
            do {
                let verifier = GmailOAuth.makeVerifier()
                let state = UUID().uuidString
                let redirect = try await LoopbackRedirect.start(expectedState: state)
                let url = GmailOAuth.authorizationURL(clientID: clientID, redirectURI: redirect.uri, state: state, verifier: verifier)
                NSWorkspace.shared.open(url)
                let code = try await redirect.waitForCode()
                try await exchange(["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                                    "redirect_uri": redirect.uri])
                address = try? await client.address()
                UserDefaults.standard.set(address, forKey: "gmailAddress")
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isConnecting = false
        }
    }

    func disconnect() {
        Keychain.save("", for: .googleRefreshToken)
        accessToken = nil
        address = nil
        UserDefaults.standard.removeObject(forKey: "gmailAddress")
    }

    // MARK: - Tokens

    private func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry > Date().addingTimeInterval(60) { return accessToken }
        let refresh = Keychain.load(.googleRefreshToken)
        guard !refresh.isEmpty else { throw GmailError.notConnected }
        try await exchange(["grant_type": "refresh_token", "refresh_token": refresh])
        guard let accessToken else { throw GmailError.notConnected }
        return accessToken
    }

    private func exchange(_ fields: [String: String]) async throws {
        var fields = fields
        fields["client_id"] = Keychain.load(.googleClientID)
        fields["client_secret"] = Keychain.load(.googleClientSecret)
        var request = URLRequest(url: GmailOAuth.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GmailOAuth.formBody(fields)

        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let token = object["access_token"] as? String else {
            // A revoked or expired refresh token: forget it, so the UI shows "not connected".
            if object["error"] as? String == "invalid_grant" { disconnect() }
            throw Failure.token(object["error_description"] as? String ?? object["error"] as? String ?? "unknown")
        }
        accessToken = token
        accessTokenExpiry = Date().addingTimeInterval(object["expires_in"] as? Double ?? 3000)
        if let refresh = object["refresh_token"] as? String { Keychain.save(refresh, for: .googleRefreshToken) }
    }
}

/// Listens on 127.0.0.1 for the single redirect that ends the consent flow.
final class LoopbackRedirect: @unchecked Sendable {
    let uri: String
    private let listener: NWListener
    private let expectedState: String
    private var continuation: CheckedContinuation<String, Error>?
    private let queue = DispatchQueue(label: "winnie.oauth.loopback")

    private init(listener: NWListener, port: UInt16, expectedState: String) {
        self.listener = listener
        self.expectedState = expectedState
        uri = "http://127.0.0.1:\(port)"
    }

    static func start(expectedState: String) async throws -> LoopbackRedirect {
        let parameters = NWParameters.tcp
        // Loopback only: nothing on the network can reach this port.
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        return try await withCheckedThrowingContinuation { ready in
            // The handler is cleared before resuming, so the continuation runs exactly once.
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port?.rawValue else { return ready.resume(throwing: GmailAuth.Failure.listener) }
                    ready.resume(returning: LoopbackRedirect(listener: listener, port: port, expectedState: expectedState))
                case .failed, .cancelled:
                    listener.stateUpdateHandler = nil
                    ready.resume(throwing: GmailAuth.Failure.listener)
                default: break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: DispatchQueue(label: "winnie.oauth.listener"))
        }
    }

    func waitForCode() async throws -> String {
        defer { listener.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.sync { self.continuation = continuation }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            // The user may simply close the browser tab.
            queue.asyncAfter(deadline: .now() + 300) { [weak self] in self?.finish(.failure(GmailAuth.Failure.cancelled)) }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            // Browsers also ask for /favicon.ico; only the real redirect carries a query.
            guard requestLine.contains("?") else { return self.respond(connection, "") }
            let code = GmailOAuth.authorizationCode(fromRequestLine: requestLine, expectedState: self.expectedState)
            self.respond(connection, code == nil ? "Вход не удался. Вернись в Winnie и попробуй ещё раз."
                                                  : "Готово. Эту вкладку можно закрыть и вернуться к Винни.")
            self.finish(code.map { .success($0) } ?? .failure(GmailAuth.Failure.cancelled))
        }
    }

    private func respond(_ connection: NWConnection, _ message: String) {
        let html = "<!doctype html><meta charset=utf-8><title>Winnie</title><body style=\"font:16px -apple-system;padding:48px\">\(message)"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
