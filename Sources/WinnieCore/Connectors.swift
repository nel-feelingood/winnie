import Foundation

/// Another application's MCP server, as the user entered it in Settings. The token is
/// not here: it lives in the Keychain under `secretName`.
public struct AppConnector: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var url: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, url: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
    }

    public var secretName: String { "connector-\(id.uuidString.lowercased())" }

    /// The API wants a plain identifier; the display name may be anything.
    public var serverName: String {
        let slug = name.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
        let cleaned = String(slug).split(separator: "-").joined(separator: "-")
        return cleaned.isEmpty ? "app-\(id.uuidString.prefix(6).lowercased())" : cleaned
    }

    public var isUsable: Bool {
        isEnabled && URL(string: url)?.scheme == "https" && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// A connector resolved for one request: its token has been read from the Keychain.
public struct MCPServer: Equatable, Sendable {
    public var name: String
    public var url: String
    public var token: String

    public init(name: String, url: String, token: String) {
        self.name = name
        self.url = url
        self.token = token
    }

    var requestEntry: [String: Any] {
        var entry: [String: Any] = ["type": "url", "name": name, "url": url]
        if !token.isEmpty { entry["authorization_token"] = token }
        return entry
    }

    /// The connector needs both halves: the server, and a toolset that points at it.
    var toolsetEntry: [String: Any] { ["type": "mcp_toolset", "mcp_server_name": name] }
}
