import AppKit
import SwiftUI

/// A plain-text Markdown editor. Two things a SwiftUI TextEditor cannot do are why this is
/// an NSTextView: a formatting menu at the caret when «/» is typed, and pasting a picture.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    /// Stores the pasted picture and returns the Markdown that embeds it.
    var onPasteImage: (NSImage) -> String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let view = SlashTextView()
        view.delegate = context.coordinator
        view.string = text
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 13)
        view.textColor = .labelColor
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = NSSize(width: 8, height: 6)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.onPasteImage = onPasteImage
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? SlashTextView else { return }
        view.onPasteImage = onPasteImage
        // Only when the text changed from outside (the bear edited the note): replacing the
        // string on every keystroke would throw the caret to the end.
        if view.string != text { view.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: MarkdownEditor

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

final class SlashTextView: NSTextView {
    var onPasteImage: (NSImage) -> String? = { _ in nil }

    /// A snippet to insert; `selection` is the placeholder to leave selected, ready to be typed over.
    private struct Format {
        let title: String
        let symbol: String
        let snippet: String
        var selection: String?
    }

    private static let formats: [Format] = [
        Format(title: "Заголовок", symbol: "textformat.size.larger", snippet: "## "),
        Format(title: "Подзаголовок", symbol: "textformat.size.smaller", snippet: "### "),
        Format(title: "Жирный", symbol: "bold", snippet: "**текст**", selection: "текст"),
        Format(title: "Курсив", symbol: "italic", snippet: "*текст*", selection: "текст"),
        Format(title: "Зачёркнутый", symbol: "strikethrough", snippet: "~~текст~~", selection: "текст"),
        Format(title: "Список", symbol: "list.bullet", snippet: "- "),
        Format(title: "Нумерованный список", symbol: "list.number", snippet: "1. "),
        Format(title: "Чек-лист", symbol: "checklist", snippet: "- [ ] "),
        Format(title: "Цитата", symbol: "text.quote", snippet: "> "),
        Format(title: "Код в строке", symbol: "chevron.left.forwardslash.chevron.right", snippet: "`код`", selection: "код"),
        Format(title: "Блок кода", symbol: "curlybraces", snippet: "```\nкод\n```\n", selection: "код"),
        Format(title: "Ссылка", symbol: "link", snippet: "[текст](https://)", selection: "текст"),
        Format(title: "Разделитель", symbol: "minus", snippet: "\n---\n"),
    ]

    // MARK: - Slash menu

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard (string as? String) == "/" else { return }
        // Only where a command makes sense: at the start of a line or after a space, not inside «и/или» or a URL.
        let caret = selectedRange().location
        let text = self.string as NSString
        let before = caret >= 2 ? text.substring(with: NSRange(location: caret - 2, length: 1)) : "\n"
        guard before == "\n" || before == " " else { return }
        showFormatMenu(slashAt: caret - 1)
    }

    private func showFormatMenu(slashAt location: Int) {
        let menu = NSMenu()
        for (index, format) in Self.formats.enumerated() {
            let item = NSMenuItem(title: format.title, action: #selector(applyFormat(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = location
            item.image = NSImage(systemSymbolName: format.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        let caretOnScreen = firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil)
        guard let window else { return }
        let inWindow = window.convertFromScreen(caretOnScreen)
        let point = convert(NSPoint(x: inWindow.minX, y: inWindow.minY - 4), from: nil)
        // Dismissing the menu leaves the «/» in place: it may simply have been a slash.
        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func applyFormat(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? Int, Self.formats.indices.contains(sender.tag) else { return }
        let format = Self.formats[sender.tag]
        let slash = NSRange(location: location, length: 1)
        guard shouldChangeText(in: slash, replacementString: format.snippet) else { return }
        replaceCharacters(in: slash, with: format.snippet)
        didChangeText()
        if let placeholder = format.selection {
            let offset = (format.snippet as NSString).range(of: placeholder)
            setSelectedRange(NSRange(location: location + offset.location, length: offset.length))
        } else {
            setSelectedRange(NSRange(location: location + (format.snippet as NSString).length, length: 0))
        }
    }

    // MARK: - Pictures

    override func paste(_ sender: Any?) {
        if let image = Self.imageOnPasteboard(), let markdown = onPasteImage(image) {
            insertText(markdown, replacementRange: selectedRange())
        } else {
            pasteAsPlainText(sender)
        }
    }

    /// Image files first (Finder also puts the file name there as text), then raw image data when there is no text.
    private static func imageOnPasteboard() -> NSImage? {
        let pasteboard = NSPasteboard.general
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true,
                     .urlReadingContentsConformToTypes: ["public.image"]]) as? [URL]) ?? []
        if let file = files.first { return NSImage(contentsOf: file) }
        guard pasteboard.string(forType: .string) == nil else { return nil }
        return NSImage(pasteboard: pasteboard)
    }
}
