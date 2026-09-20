import Foundation

/// Pulls the links out of a Markdown answer so they can be listed under it, where
/// each one gets its own hover actions — impossible for a link buried inside
/// rendered text.
public enum LinkExtractor {
    private static let markdownLink = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((https?://[^\s)]+)\)"#)
    private static let bareURL = try! NSRegularExpression(pattern: #"https?://[^\s<>()\[\]"'`]+"#)

    public static func links(in markdown: String) -> [Source] {
        let text = markdown as NSString
        let whole = NSRange(location: 0, length: text.length)
        var found: [(position: Int, source: Source)] = []
        var claimed: [NSRange] = []

        for match in markdownLink.matches(in: markdown, range: whole) {
            let url = text.substring(with: match.range(at: 2))
            found.append((match.range.location, Source(title: text.substring(with: match.range(at: 1)), url: url)))
            claimed.append(match.range)
        }
        for match in bareURL.matches(in: markdown, range: whole)
        where !claimed.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            // Sentence punctuation right after a URL is not part of it.
            let url = text.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            found.append((match.range.location, Source(title: displayTitle(for: url), url: url)))
        }

        var seen = Set<String>()
        return found.sorted { $0.position < $1.position }
            .map(\.source)
            .filter { seen.insert($0.url).inserted }
    }

    /// Cited sources first (they are what the answer rests on), then any other link in the text.
    public static func allLinks(for message: ChatMessage) -> [Source] {
        var seen = Set(message.sources.map(\.url))
        return message.sources + links(in: message.text).filter { seen.insert($0.url).inserted }
    }

    static func displayTitle(for url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return components.path.count > 1 ? site + components.path : site
    }
}
