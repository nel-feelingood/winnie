import Foundation

/// Splits a Markdown text into ordinary Markdown and task-list lines, so that each checkbox
/// can be drawn as a real control that knows which line of the text it stands for.
public enum TaskList {
    public enum Segment: Equatable, Identifiable, Sendable {
        case markdown(id: Int, text: String)
        case task(line: Int, indent: Int, isDone: Bool, text: String)

        public var id: Int {
            switch self {
            case .markdown(let id, _): id
            case .task(let line, _, _, _): line
            }
        }
    }

    private static let pattern = try! NSRegularExpression(pattern: #"^(\s*)(?:[-*+]|\d+[.)])\s+\[([ xX])\]\s+(.*)$"#)

    static func task(in line: String) -> (indent: Int, isDone: Bool, text: String)? {
        let text = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else { return nil }
        let indent = text.substring(with: match.range(at: 1)).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return (indent / 2, text.substring(with: match.range(at: 2)) != " ", text.substring(with: match.range(at: 3)))
    }

    public static func segments(of body: String) -> [Segment] {
        var segments: [Segment] = []
        var pending: [String] = []
        var pendingStart = 0
        var insideCode = false

        func flush() {
            let text = pending.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.markdown(id: pendingStart, text: text)) }
            pending = []
        }

        for (index, line) in body.components(separatedBy: "\n").enumerated() {
            // «- [ ]» inside a code block is code, not a checkbox.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { insideCode.toggle() }
            if !insideCode, let task = task(in: line) {
                flush()
                segments.append(.task(line: index, indent: task.indent, isDone: task.isDone, text: task.text))
            } else {
                if pending.isEmpty { pendingStart = index }
                pending.append(line)
            }
        }
        flush()
        return segments
    }

    /// Flips the checkbox on one line and leaves every other character of the text alone.
    public static func toggling(line index: Int, in body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        // Asked of `segments`, which knows about code blocks: a «- [ ]» inside one is not a checkbox.
        let isTask = segments(of: body).contains { if case .task(let line, _, _, _) = $0 { line == index } else { false } }
        guard isTask, lines.indices.contains(index),
              let box = lines[index].range(of: #"\[([ xX])\]"#, options: .regularExpression) else { return body }
        lines[index].replaceSubrange(box, with: lines[index][box] == "[ ]" ? "[x]" : "[ ]")
        return lines.joined(separator: "\n")
    }
}
