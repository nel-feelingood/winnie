import AppKit
import SwiftUI
import WinnieCore

/// The note editor. The text is plain Markdown and stays that way; it is styled in place as it
/// is typed (headings large, emphasis shown, syntax dimmed, checkboxes clickable, pictures drawn
/// under their line), so there is no separate preview to switch to.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    /// Stores the pasted picture and returns the Markdown that embeds it.
    var onPasteImage: (NSImage) -> String?
    /// Resolves a picture's relative path (`images/….jpg`) to a file.
    var imageURL: (String) -> URL

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        // TextKit 1 on purpose: drawing pictures under a line needs the layout manager's line rectangles.
        let view = SlashTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.imageURL = imageURL
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
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        view.restyle()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? SlashTextView else { return }
        view.onPasteImage = onPasteImage
        // Only when the text changed from outside (the bear edited the note): replacing the
        // string on every keystroke would throw the caret to the end.
        if view.string != text {
            view.string = text
            view.restyle()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: MarkdownEditor

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? SlashTextView else { return }
            view.restyle()
            parent.text = view.string
        }
    }
}

final class SlashTextView: NSTextView {
    var onPasteImage: (NSImage) -> String? = { _ in nil }
    var imageURL: (String) -> URL = { URL(fileURLWithPath: $0) }

    private var pictures: [(range: NSRange, image: NSImage, size: NSSize)] = []
    private var imageCache: [String: NSImage] = [:]

    private static let bodySize: CGFloat = 13
    private static let pictureGap: CGFloat = 6
    private static let maxPictureHeight: CGFloat = 280

    // MARK: - Styling

    /// Re-styles the whole text. Notes are short, so this is cheaper and far simpler than tracking edits;
    /// only attributes change, never characters, so the undo stack and the caret are untouched.
    func restyle() {
        guard let storage = textStorage else { return }
        let text = string
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let body = NSFont.systemFont(ofSize: Self.bodySize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 4

        storage.beginEditing()
        storage.setAttributes([.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: whole)
        pictures = []
        for span in MarkdownSpans.spans(in: text) where NSMaxRange(span.range) <= whole.length {
            switch span.style {
            case .marker:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
            case .heading(let level):
                let size: CGFloat = [20, 17, 15][min(level, 3) - 1]
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: span.range)
            case .bold:
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: Self.bodySize, weight: .bold), range: span.range)
            case .italic:
                storage.addAttribute(.font, value: NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask), range: span.range)
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
            case .code, .codeBlock:
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: Self.bodySize - 1, weight: .regular),
                                       .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07)], range: span.range)
            case .quote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
            case .link:
                storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .cursor: NSCursor.pointingHand, .toolTip: "⌘-клик — открыть"], range: span.range)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: span.range)
            case .checkbox(let isDone):
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: Self.bodySize, weight: .semibold),
                                       .foregroundColor: isDone ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                                       .cursor: NSCursor.pointingHand], range: span.range)
            case .done:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: NSColor.tertiaryLabelColor], range: span.range)
            case .image(let path):
                storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor,
                                       .font: NSFont.systemFont(ofSize: 10)], range: span.range)
                reservePicture(path, for: span.range, in: storage, base: paragraph)
            }
        }
        storage.endEditing()
        needsDisplay = true
    }

    /// Makes room under the line that names a picture; `draw` fills it.
    private func reservePicture(_ path: String, for range: NSRange, in storage: NSTextStorage, base: NSParagraphStyle) {
        guard let image = picture(at: path) else { return }
        let available = max(120, (textContainer?.size.width ?? 340) - 2 * (textContainer?.lineFragmentPadding ?? 5))
        let scale = min(1, available / image.size.width, Self.maxPictureHeight / image.size.height)
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let style = base.mutableCopy() as! NSMutableParagraphStyle
        style.paragraphSpacing = size.height + Self.pictureGap * 2
        storage.addAttribute(.paragraphStyle, value: style, range: (storage.string as NSString).paragraphRange(for: range))
        pictures.append((range, image, size))
    }

    private func picture(at path: String) -> NSImage? {
        if let cached = imageCache[path] { return cached }
        guard let image = NSImage(contentsOf: imageURL(path)) else { return nil }
        imageCache[path] = image
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer else { return }
        for picture in pictures where NSMaxRange(picture.range) <= (string as NSString).length {
            let paragraph = (string as NSString).paragraphRange(for: picture.range)
            let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            // The last line of the paragraph: the space reserved by `paragraphSpacing` lies right under its text.
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let origin = NSPoint(x: textContainerOrigin.x + textContainer.lineFragmentPadding,
                                 y: textContainerOrigin.y + used.maxY + Self.pictureGap)
            let rect = NSRect(origin: origin, size: picture.size)
            guard rect.intersects(dirtyRect) else { continue }
            let clip = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            picture.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Pictures are sized to the text width, so a resize has to lay them out again.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, !pictures.isEmpty { restyle() }
    }

    /// The address of the Markdown link whose title contains this character.
    private func linkURL(at index: Int) -> URL? {
        let text = string as NSString
        let pattern = try? NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
        for match in pattern?.matches(in: string, range: NSRange(location: 0, length: text.length)) ?? []
        where NSLocationInRange(index, match.range) {
            return URL(string: text.substring(with: match.range(at: 2)))
        }
        return nil
    }

    // MARK: - Checkboxes

    /// A click on «[ ]» toggles it instead of placing the caret inside it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let text = string
        for candidate in [index, index - 1] where candidate >= 0 {
            guard let box = MarkdownSpans.checkbox(at: candidate, in: text) else { continue }
            let replacement = box.isDone ? "[ ]" : "[x]"
            guard shouldChangeText(in: box.range, replacementString: replacement) else { return }
            replaceCharacters(in: box.range, with: replacement)
            didChangeText()
            return
        }
        // A plain click on a link places the caret, as editing needs; ⌘-click follows it.
        if event.modifierFlags.contains(.command), let url = linkURL(at: index) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

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
