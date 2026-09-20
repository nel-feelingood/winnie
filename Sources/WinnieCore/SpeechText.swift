import Foundation

/// Turns a streamed Markdown answer into sentences a speech synthesizer can read.
public enum SpeechText {
    private static let replacements: [(NSRegularExpression, String)] = [
        (#"```[\s\S]*?```"#, " "),                 // code blocks are for the eyes
        (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),         // links keep their title
        (#"https?://\S+"#, " "),
        (#"(?m)^\s*(?:[-*+]|\d+[.)])\s+"#, ""),    // list markers
        (#"(?m)^\s*#{1,6}\s+"#, ""),
        (#"[*_`~>|]"#, ""),
        (#"[ \t]+"#, " "),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func clean(_ markdown: String) -> String {
        var text = markdown
        for (regex, template) in replacements {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: template)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes and returns the complete sentences at the front of `buffer`, leaving the
    /// unfinished tail for the next delta, so speech can start before the answer ends.
    public static func popSentences(from buffer: inout String) -> [String] {
        // An open code fence would be read aloud symbol by symbol; wait until it closes.
        guard buffer.components(separatedBy: "```").count % 2 == 1 else { return [] }
        var sentences: [String] = []
        var start = buffer.startIndex
        var index = start
        while index < buffer.endIndex {
            let character = buffer[index]
            let next = buffer.index(after: index)
            let endsSentence = ".!?…".contains(character) && next < buffer.endIndex && buffer[next].isWhitespace
            if endsSentence || character == "\n" {
                let sentence = clean(String(buffer[start..<next]))
                if !sentence.isEmpty { sentences.append(sentence) }
                start = next
            }
            index = next
        }
        buffer = String(buffer[start...].drop(while: \.isWhitespace))
        return sentences
    }
}
