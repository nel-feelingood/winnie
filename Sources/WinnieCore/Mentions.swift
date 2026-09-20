import Foundation

/// References to the app's own objects inside chat text: `[note:1a2b3c4d]`, `[event:9f8e7d6c]`.
/// To the model they are plain text it can read and write; the app draws them as links.
public enum Mentions {
    public enum Kind: String, CaseIterable, Sendable {
        case note, event

        public var glyph: String { self == .note ? "📝" : "🔔" }
    }

    public struct Target: Equatable, Sendable {
        public var kind: Kind
        public var id: String

        public init(kind: Kind, id: String) {
            self.kind = kind
            self.id = id
        }

        public var token: String { "[\(kind.rawValue):\(id)]" }
        public var url: URL { URL(string: "winnie://\(kind.rawValue)/\(id)")! }
    }

    private static let token = try! NSRegularExpression(pattern: #"\[(note|event):([0-9a-fA-F]{6,8})\]"#)

    /// The object a `winnie://note/…` link points at.
    public static func target(of url: URL) -> Target? {
        guard url.scheme == "winnie", let kind = url.host.flatMap(Kind.init) else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return id.isEmpty ? nil : Target(kind: kind, id: id)
    }

    /// Every reference in `text`, with the range it occupies.
    public static func references(in text: String) -> [(range: Range<String.Index>, target: Target)] {
        let source = text as NSString
        return token.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard let range = Range(match.range, in: text), let kind = Kind(rawValue: source.substring(with: match.range(at: 1))) else { return nil }
            return (range, Target(kind: kind, id: source.substring(with: match.range(at: 2)).lowercased()))
        }
    }

    /// Markdown in which each reference has become a link titled with the object's name.
    /// A reference to something that no longer exists stays visible, struck through.
    public static func linkified(_ markdown: String, title: (Target) -> String?) -> String {
        var result = markdown
        for reference in references(in: markdown).reversed() {
            let replacement: String
            if let name = title(reference.target) {
                let safe = name.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
                replacement = "[\(reference.target.kind.glyph) \(safe)](\(reference.target.url.absoluteString))"
            } else {
                replacement = "~~\(reference.target.kind.glyph) удалено~~"
            }
            result.replaceSubrange(reference.range, with: replacement)
        }
        return result
    }

    // MARK: - Typing «@»

    /// The text after an «@» the user is in the middle of typing at the end of the draft; nil when
    /// they are not. «@» counts only at the start or after whitespace, so e-mail addresses do not trigger it.
    public static func trailingQuery(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let query = draft[draft.index(after: at)...]
        return query.contains(where: \.isNewline) || query.count > 40 ? nil : String(query)
    }

    /// Replaces the «@query» being typed with the chosen object's reference.
    public static func completing(_ draft: String, with target: Target) -> String {
        guard trailingQuery(in: draft) != nil, let at = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<at]) + target.token + " "
    }
}
