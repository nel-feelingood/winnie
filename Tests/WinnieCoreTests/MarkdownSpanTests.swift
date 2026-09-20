import Foundation
import Testing
@testable import WinnieCore

@Suite struct MarkdownSpanTests {
    func styled(_ text: String) -> [(String, MarkdownSpans.Style)] {
        MarkdownSpans.spans(in: text).map { ((text as NSString).substring(with: $0.range), $0.style) }
    }

    func expect(_ text: String, contains piece: String, as style: MarkdownSpans.Style, _ comment: Comment? = nil) {
        #expect(styled(text).contains { $0.0 == piece && $0.1 == style }, comment ?? "\(piece) should be \(style) in: \(text)")
    }

    @Test func headingsQuotesAndRules() {
        expect("## План поездки", contains: "## ", as: .marker)
        expect("## План поездки", contains: "План поездки", as: .heading(level: 2))
        expect("> цитата", contains: "цитата", as: .quote)
        expect("---", contains: "---", as: .marker)
        #expect(styled("#хештег без пробела").isEmpty)
    }

    @Test func inlineStyles() {
        let text = "это **жирный**, *курсив*, ~~зачёркнутый~~ и `код`"
        expect(text, contains: "жирный", as: .bold)
        expect(text, contains: "курсив", as: .italic)
        expect(text, contains: "зачёркнутый", as: .strike)
        expect(text, contains: "код", as: .code)
        // A lone asterisk or an arithmetic one is not emphasis.
        #expect(!styled("2 * 3 * 4").contains { $0.1 == .italic })
        #expect(!styled("**жирный**").contains { $0.1 == .italic })
    }

    @Test func tasksListsAndLinks() {
        let text = "- [x] перекур\n- [ ] прогулка\n  1. вложенный\nсм. [сайт](https://a.b)"
        expect(text, contains: "[x]", as: .checkbox(isDone: true))
        expect(text, contains: "перекур", as: .done)
        expect(text, contains: "[ ]", as: .checkbox(isDone: false))
        #expect(!styled(text).contains { $0.0 == "прогулка" && $0.1 == .done })
        expect(text, contains: "  1. ", as: .listMarker)
        expect(text, contains: "сайт", as: .link)
        expect(text, contains: "](https://a.b)", as: .marker)
    }

    @Test func codeBlocksAreLeftAlone() {
        let text = "```\n- [ ] **не разметка**\n```"
        #expect(styled(text).map(\.1) == [.marker, .codeBlock, .marker])
    }

    @Test func picturesAreFoundWithTheirPath() {
        expect("до ![шот](images/a1.jpg) после", contains: "![шот](images/a1.jpg)", as: .image(path: "images/a1.jpg"))
        #expect(!styled("![](images/a1.jpg)").contains { $0.1 == .link })
    }

    @Test func aClickFindsItsCheckbox() {
        let text = "вступление\n- [ ] первая\n- [x] вторая"
        let first = (text as NSString).range(of: "[ ]")
        #expect(MarkdownSpans.checkbox(at: first.location + 1, in: text)?.isDone == false)
        #expect(MarkdownSpans.checkbox(at: (text as NSString).range(of: "[x]").location, in: text)?.isDone == true)
        #expect(MarkdownSpans.checkbox(at: 2, in: text) == nil)
    }
}
