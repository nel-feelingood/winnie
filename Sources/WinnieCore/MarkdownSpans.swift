import Foundation

/// What each stretch of a Markdown text is, for an editor that styles the text in place while
/// it stays plain Markdown underneath. Ranges are NSRange: they go straight to NSTextStorage.
public enum MarkdownSpans {
    public enum Style: Equatable, Sendable {
        /// Syntax characters (`#`, `**`, `>`, a link's URL part): shown, but dimmed.
        case marker
        case heading(level: Int)
        case bold, italic, strike, code, codeBlock, quote, link
        case listMarker
        /// The «[ ]» / «[x]» of a task item: drawn as a control and clickable.
        case checkbox(isDone: Bool)
        /// The text of a finished task.
        case done
        /// A whole `![](path)` line; the picture is drawn beneath it.
        case image(path: String)
    }

    public struct Span: Equatable, Sendable {
        public var range: NSRange
        public var style: Style
    }

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }

    private static let heading = regex(#"^(#{1,6})[ \t]+(.*)$"#)
    private static let quote = regex(#"^([ \t]*>[ \t]?)(.*)$"#)
    private static let listItem = regex(#"^([ \t]*(?:[-*+]|\d+[.)])[ \t]+)(?:(\[[ xX]\])[ \t]+)?(.*)$"#)
    private static let rule = regex(#"^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#)
    private static let image = regex(#"!\[[^\]]*\]\(([^)\s]+)\)"#)
    private static let inline: [(NSRegularExpression, Style)] = [
        (regex(#"(\*\*)(?=\S)(.+?)(?<=\S)(\*\*)"#), .bold),
        (regex(#"(?<![\*\w])(\*)(?=[^\s\*])(.+?)(?<=[^\s\*])(\*)(?![\*\w])"#), .italic),
        (regex(#"(~~)(?=\S)(.+?)(?<=\S)(~~)"#), .strike),
        (regex(#"(`)([^`\n]+)(`)"#), .code),
    ]
    private static let link = regex(#"(?<!!)(\[)([^\]\n]+)(\]\([^)\n]*\))"#)

    public static func spans(in text: String) -> [Span] {
        var spans: [Span] = []
        let source = text as NSString
        var insideCode = false
        var location = 0

        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let lineRange = NSRange(location: location, length: length)
            defer { location += length + 1 }

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideCode.toggle()
                spans.append(Span(range: lineRange, style: .marker))
                continue
            }
            if insideCode {
                spans.append(Span(range: lineRange, style: .codeBlock))
                continue
            }
            guard length > 0 else { continue }

            func shifted(_ range: NSRange) -> NSRange { NSRange(location: range.location + location, length: range.length) }
            let whole = NSRange(location: 0, length: length)
            var inlineRange = lineRange

            if let match = heading.firstMatch(in: line, range: whole) {
                spans.append(Span(range: shifted(NSRange(location: 0, length: match.range(at: 2).location)), style: .marker))
                spans.append(Span(range: shifted(match.range(at: 2)), style: .heading(level: match.range(at: 1).length)))
                inlineRange = shifted(match.range(at: 2))
            } else if rule.firstMatch(in: line, range: whole) != nil {
                spans.append(Span(range: lineRange, style: .marker))
                continue
            } else if let match = quote.firstMatch(in: line, range: whole) {
                spans.append(Span(range: shifted(match.range(at: 1)), style: .marker))
                spans.append(Span(range: shifted(match.range(at: 2)), style: .quote))
                inlineRange = shifted(match.range(at: 2))
            } else if let match = listItem.firstMatch(in: line, range: whole) {
                spans.append(Span(range: shifted(match.range(at: 1)), style: .listMarker))
                inlineRange = shifted(match.range(at: 3))
                if match.range(at: 2).location != NSNotFound {
                    let isDone = (line as NSString).substring(with: match.range(at: 2)) != "[ ]"
                    spans.append(Span(range: shifted(match.range(at: 2)), style: .checkbox(isDone: isDone)))
                    if isDone { spans.append(Span(range: inlineRange, style: .done)) }
                }
            }

            for match in image.matches(in: text, range: lineRange) {
                spans.append(Span(range: match.range, style: .image(path: source.substring(with: match.range(at: 1)))))
            }
            for (pattern, style) in inline {
                for match in pattern.matches(in: text, range: inlineRange) {
                    spans.append(Span(range: match.range(at: 1), style: .marker))
                    spans.append(Span(range: match.range(at: 2), style: style))
                    spans.append(Span(range: match.range(at: 3), style: .marker))
                }
            }
            for match in link.matches(in: text, range: inlineRange) {
                spans.append(Span(range: match.range(at: 1), style: .marker))
                spans.append(Span(range: match.range(at: 2), style: .link))
                spans.append(Span(range: match.range(at: 3), style: .marker))
            }
        }
        return spans
    }

    /// The task checkbox at a character position, if there is one: what a click in the editor hits.
    public static func checkbox(at location: Int, in text: String) -> (range: NSRange, isDone: Bool)? {
        for span in spans(in: text) {
            if case .checkbox(let isDone) = span.style, NSLocationInRange(location, span.range) { return (span.range, isDone) }
        }
        return nil
    }
}
