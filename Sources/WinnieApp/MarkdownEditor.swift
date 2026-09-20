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
        view.layoutManager?.delegate = view
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

        /// Syntax is shown only on the caret's line, so moving to another line restyles.
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? SlashTextView)?.caretMoved()
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? SlashTextView else { return }
            view.restyle()
            parent.text = view.string
        }
    }
}

private extension NSAttributedString.Key {
    /// Characters the layout manager should not draw at all (syntax away from the caret).
    static let hiddenMarkup = NSAttributedString.Key("winnie.hiddenMarkup")
    /// A list dash shown as «•».
    static let bullet = NSAttributedString.Key("winnie.bullet")
}

final class SlashTextView: NSTextView, NSLayoutManagerDelegate {
    var onPasteImage: (NSImage) -> String? = { _ in nil }
    var imageURL: (String) -> URL = { URL(fileURLWithPath: $0) }

    private var pictures: [(range: NSRange, image: NSImage, size: NSSize)] = []
    private var checkboxes: [(range: NSRange, isDone: Bool)] = []
    private var codeBlocks: [NSRange] = []
    private var fences: [NSRange] = []
    private var quotes: [NSRange] = []
    private var rules: [NSRange] = []
    private var imageCache: [String: NSImage] = [:]
    private var revealedParagraph = NSRange(location: NSNotFound, length: 0)

    private static let bodySize: CGFloat = 13
    private static let pictureGap: CGFloat = 6
    private static let maxPictureHeight: CGFloat = 280

    // MARK: - Styling

    /// The paragraph whose syntax is shown: the caret's, and only while this view has the keyboard.
    private var caretParagraph: NSRange {
        guard window?.firstResponder === self else { return NSRange(location: NSNotFound, length: 0) }
        return (string as NSString).paragraphRange(for: selectedRange())
    }

    func caretMoved() {
        if !NSEqualRanges(caretParagraph, revealedParagraph) { restyle() }
        updateFormatBar()
    }

    // MARK: - Formatting bar

    private lazy var formatBar: FormatBar = {
        let bar = FormatBar { [weak self] action in self?.apply(action) }
        bar.isHidden = true
        addSubview(bar)
        return bar
    }()
    private var formatBarTask: Task<Void, Never>?

    /// Shown above a selection, once the mouse button is up so it does not chase the drag.
    private func updateFormatBar() {
        formatBarTask?.cancel()
        guard selectedRange().length > 0, window?.firstResponder === self else { return formatBar.isHidden = true }
        formatBarTask = Task { [weak self] in
            while NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(40))
                if Task.isCancelled { return }
            }
            self?.placeFormatBar()
        }
    }

    private func placeFormatBar() {
        let selection = selectedRange()
        guard selection.length > 0, let window else { return formatBar.isHidden = true }
        let onScreen = firstRect(forCharacterRange: selection, actualRange: nil)
        let area = convert(window.convertFromScreen(onScreen), from: nil)
        var origin = NSPoint(x: area.midX - formatBar.frame.width / 2, y: area.minY - formatBar.frame.height - 6)
        origin.x = min(max(origin.x, 4), max(4, bounds.width - formatBar.frame.width - 4))
        // No room above the first lines: go below the selection instead.
        if origin.y < visibleRect.minY + 2 { origin.y = area.maxY + 6 }
        formatBar.setFrameOrigin(origin)
        formatBar.isHidden = false
    }

    private func apply(_ action: FormatBar.Action) {
        switch action {
        case .wrap(let mark): toggleWrap(mark)
        case .linePrefix(let prefix): toggleLinePrefix(prefix)
        case .link: wrapAsLink()
        }
    }

    /// «**выделенное**», or back to plain if it is already wrapped that way.
    private func toggleWrap(_ mark: String) {
        let selection = selectedRange()
        let text = string as NSString
        let length = (mark as NSString).length
        let outer = NSRange(location: selection.location - length, length: selection.length + 2 * length)
        let isWrapped = outer.location >= 0 && NSMaxRange(outer) <= text.length
            && text.substring(with: NSRange(location: outer.location, length: length)) == mark
            && text.substring(with: NSRange(location: NSMaxRange(selection), length: length)) == mark
        let inner = text.substring(with: selection)
        replace(isWrapped ? outer : selection, with: isWrapped ? inner : mark + inner + mark,
                select: NSRange(location: isWrapped ? outer.location : selection.location + length, length: selection.length))
    }

    /// Adds «## », «- », «> »… to every selected line, or removes it if they all have it.
    private func toggleLinePrefix(_ prefix: String) {
        let text = string as NSString
        let lines = text.paragraphRange(for: selectedRange())
        let content = text.substring(with: lines)
        let endsWithNewline = content.hasSuffix("\n")
        var parts = content.components(separatedBy: "\n")
        if endsWithNewline { parts.removeLast() }
        let known = ["# ", "## ", "### ", "- [ ] ", "- [x] ", "- ", "1. ", "> "]
        let allHave = parts.allSatisfy { $0.hasPrefix(prefix) || $0.isEmpty }
        parts = parts.map { line in
            guard !line.isEmpty else { return line }
            if allHave { return String(line.dropFirst(prefix.count)) }
            // Switching kind (a list into a heading) replaces the old prefix instead of stacking on it.
            let bare = known.first(where: { line.hasPrefix($0) }).map { String(line.dropFirst($0.count)) } ?? line
            return prefix + bare
        }
        let result = parts.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        replace(lines, with: result, select: NSRange(location: lines.location, length: (result as NSString).length - (endsWithNewline ? 1 : 0)))
    }

    private func wrapAsLink() {
        let selection = selectedRange()
        let inner = (string as NSString).substring(with: selection)
        let result = "[\(inner)](https://)"
        // Leaves «https://» selected, ready to be typed over.
        replace(selection, with: result, select: NSRange(location: selection.location + (inner as NSString).length + 3, length: 8))
    }

    private func replace(_ range: NSRange, with text: String, select: NSRange) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(select)
    }

    override func becomeFirstResponder() -> Bool {
        defer { DispatchQueue.main.async { [weak self] in self?.restyle() } }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { DispatchQueue.main.async { [weak self] in self?.restyle() } }
        return super.resignFirstResponder()
    }

    /// Re-styles the whole text. Notes are short, so this is cheaper and far simpler than tracking edits;
    /// only attributes change, never characters, so the undo stack and the caret are untouched.
    ///
    /// The look is that of rendered Markdown: syntax characters are not drawn at all. The exception is
    /// the line the caret is on, where they reappear (dimmed) so they can be edited.
    func restyle() {
        guard let storage = textStorage else { return }
        let text = string
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        let body = NSFont.systemFont(ofSize: Self.bodySize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 4
        let revealed = caretParagraph
        revealedParagraph = revealed
        func isRevealed(_ range: NSRange) -> Bool {
            revealed.location != NSNotFound && NSIntersectionRange(source.paragraphRange(for: range), revealed).length > 0
        }
        /// Syntax: gone, or dimmed when its line is being edited.
        func markup(_ range: NSRange) {
            if isRevealed(range) {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
            } else {
                storage.addAttribute(.hiddenMarkup, value: true, range: range)
            }
        }

        let spans = MarkdownSpans.spans(in: text).filter { NSMaxRange($0.range) <= whole.length }
        let taskLines = Set(spans.compactMap { span -> Int? in
            if case .checkbox = span.style { return source.paragraphRange(for: span.range).location }
            return nil
        })

        storage.beginEditing()
        storage.setAttributes([.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: whole)
        pictures = []; checkboxes = []; codeBlocks = []; fences = []; quotes = []; rules = []

        for span in spans {
            switch span.style {
            case .marker:
                markup(span.range)
            case .fence:
                markup(span.range)
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), range: span.range)
                if !isRevealed(span.range) {
                    // Hidden, the line would still stand as a blank one; squeeze it to a sliver of padding.
                    let thin = NSMutableParagraphStyle()
                    thin.maximumLineHeight = 5
                    thin.paragraphSpacing = 0
                    storage.addAttribute(.paragraphStyle, value: thin, range: source.paragraphRange(for: span.range))
                }
                fences.append(span.range)
            case .rule:
                markup(span.range)
                rules.append(span.range)
            case .quoteMarker:
                markup(span.range)
            case .heading(let level):
                let size: CGFloat = [20, 17, 15][min(level, 3) - 1]
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: span.range)
            case .bold:
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: Self.bodySize, weight: .bold), range: span.range)
            case .italic:
                let current = storage.attribute(.font, at: span.range.location, effectiveRange: nil) as? NSFont ?? body
                storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: .italicFontMask), range: span.range)
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
            case .code:
                // Marked by typeface and colour. A background is not reliable here: next to the hidden backticks
                // TextKit reports a wrapped run as zero-width, so a drawn box lands in the wrong place.
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: Self.bodySize - 1, weight: .medium),
                                       .foregroundColor: NSColor.systemOrange], range: span.range)
            case .codeBlock:
                // The background is one rounded block drawn behind the lines, not a ragged strip per line.
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: Self.bodySize - 1, weight: .regular), range: span.range)
                codeBlocks.append(span.range)
            case .quote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
                let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                style.firstLineHeadIndent = 12
                style.headIndent = 12
                storage.addAttribute(.paragraphStyle, value: style, range: source.paragraphRange(for: span.range))
                quotes.append(span.range)
            case .link:
                storage.addAttributes([.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand,
                                       .toolTip: "⌘-клик — открыть"], range: span.range)
            case .listMarker:
                styleListMarker(span.range, isTask: taskLines.contains(source.paragraphRange(for: span.range).location),
                                isRevealed: isRevealed(span.range), in: storage)
            case .checkbox(let isDone):
                // The three characters keep their room but are invisible; a drawn box goes on top.
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: Self.bodySize, weight: .regular),
                                       .foregroundColor: NSColor.clear, .cursor: NSCursor.pointingHand], range: span.range)
                checkboxes.append((span.range, isDone))
            case .done:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: NSColor.tertiaryLabelColor], range: span.range)
            case .image(let path):
                markup(span.range)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 10), range: span.range)
                reservePicture(path, for: span.range, in: storage, base: paragraph)
            }
        }
        storage.endEditing()
        // Hidden-ness is decided when glyphs are generated, so an attribute change alone would not show.
        layoutManager?.invalidateGlyphs(forCharacterRange: whole, changeInLength: 0, actualCharacterRange: nil)
        layoutManager?.invalidateLayout(forCharacterRange: whole, actualCharacterRange: nil)
        needsDisplay = true
    }

    /// «- » becomes a bullet; in a task item it disappears, since the checkbox stands in for it. Numbers stay as typed.
    private func styleListMarker(_ range: NSRange, isTask: Bool, isRevealed: Bool, in storage: NSTextStorage) {
        let marker = (storage.string as NSString).substring(with: range)
        guard let offset = marker.firstIndex(where: { !$0.isWhitespace }).map({ marker.distance(from: marker.startIndex, to: $0) }) else { return }
        let sign = NSRange(location: range.location + offset, length: 1)
        let isDash = "-*+".contains(marker[marker.index(marker.startIndex, offsetBy: offset)])
        if isRevealed {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: sign.location, length: range.length - offset))
        } else if isTask {
            storage.addAttribute(.hiddenMarkup, value: true, range: NSRange(location: sign.location, length: range.length - offset))
        } else if isDash {
            storage.addAttribute(.bullet, value: true, range: sign)
        }
    }

    // MARK: - NSLayoutManagerDelegate

    /// Hides syntax and swaps list dashes for bullets at the glyph level; the characters themselves never change.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var newProperties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        var changed = false
        for index in 0..<glyphRange.length {
            let character = characterIndexes[index]
            guard character < storage.length else { continue }
            if storage.attribute(.hiddenMarkup, at: character, effectiveRange: nil) != nil {
                newProperties[index] = .null
                changed = true
            } else if storage.attribute(.bullet, at: character, effectiveRange: nil) != nil {
                var bullet: [UniChar] = [0x2022]
                var glyph: [CGGlyph] = [0]
                if CTFontGetGlyphsForCharacters(font as CTFont, &bullet, &glyph, 1) {
                    newGlyphs[index] = glyph[0]
                    changed = true
                }
            }
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(newGlyphs, properties: newProperties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    // MARK: - Drawing

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

    /// The glyphs of a character range without hidden ones at either end. A hidden neighbour (a closing
    /// backtick, say) is reported as part of the range but sits elsewhere, and measuring it gives nonsense.
    private func visibleGlyphs(for range: NSRange) -> NSRange? {
        guard let layoutManager, NSMaxRange(range) <= (string as NSString).length else { return nil }
        var glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        while glyphs.length > 0, layoutManager.propertyForGlyph(at: NSMaxRange(glyphs) - 1).contains(.null) { glyphs.length -= 1 }
        while glyphs.length > 0, layoutManager.propertyForGlyph(at: glyphs.location).contains(.null) {
            glyphs.location += 1
            glyphs.length -= 1
        }
        return glyphs.length > 0 ? glyphs : nil
    }

    /// The rectangle a run of characters occupies, in view coordinates.
    private func rect(of range: NSRange, fullWidth: Bool = false) -> NSRect? {
        guard let layoutManager, let textContainer, let glyphs = visibleGlyphs(for: range) else { return nil }
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        if fullWidth {
            rect.origin.x = textContainer.lineFragmentPadding
            rect.size.width = textContainer.size.width - 2 * textContainer.lineFragmentPadding
        }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // Restyling invalidates glyphs and layout; measuring before they are rebuilt gives empty rectangles.
        if let textContainer { layoutManager?.ensureLayout(for: textContainer) }
        // Consecutive code lines form one block. Rectangles come from visible text only: hidden glyphs are
        // laid out at the end of the previous line, so measuring them would pull the block upward.
        var block: NSRect?
        var previousEnd = -1
        func flush() {
            guard let area = block else { return }
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: area.insetBy(dx: -2, dy: -5), xRadius: 6, yRadius: 6).fill()
            block = nil
        }
        for range in codeBlocks.sorted(by: { $0.location < $1.location }) {
            guard let line = lineRect(at: range.location) else { continue }
            // Adjacent means: the previous code line ends right before this one (a newline apart).
            if range.location != previousEnd + 1 { flush() }
            block = block.map { $0.union(line) } ?? line
            previousEnd = NSMaxRange(range)
        }
        flush()

        NSColor.tertiaryLabelColor.setFill()
        for range in quotes {
            // The quoted text itself, not its paragraph: the hidden «>» would be measured on the line above.
            guard let line = self.rect(of: range, fullWidth: true) else { continue }
            NSBezierPath(roundedRect: NSRect(x: line.minX, y: line.minY, width: 3, height: line.height), xRadius: 1.5, yRadius: 1.5).fill()
        }
        NSColor.separatorColor.setFill()
        for range in rules where NSIntersectionRange((string as NSString).paragraphRange(for: range), revealedParagraph).length == 0 {
            guard let line = lineRect(at: range.location) else { continue }
            NSRect(x: line.minX, y: line.midY, width: line.width, height: 1).fill()
        }
    }

    /// The full-width rectangle of the line holding a character, which also works for lines whose glyphs are all hidden.
    private func lineRect(at location: Int) -> NSRect? {
        guard let layoutManager, let textContainer, location <= (string as NSString).length, layoutManager.numberOfGlyphs > 0 else { return nil }
        let glyph = min(layoutManager.glyphIndexForCharacter(at: location), layoutManager.numberOfGlyphs - 1)
        var line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        line.origin.x = textContainer.lineFragmentPadding
        line.size.width = textContainer.size.width - 2 * textContainer.lineFragmentPadding
        return line.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer else { return }

        for box in checkboxes {
            guard let area = rect(of: box.range) else { continue }
            let side: CGFloat = 14
            let frame = NSRect(x: area.minX + 1, y: area.midY - side / 2, width: side, height: side)
            let symbol = NSImage(systemSymbolName: box.isDone ? "checkmark.square.fill" : "square", accessibilityDescription: nil)?
                // Two palette colours for the filled box: the tick, then the square. One colour would paint both alike.
                .withSymbolConfiguration(.init(pointSize: side, weight: .regular)
                    .applying(.init(paletteColors: box.isDone ? [.white, .controlAccentColor] : [.secondaryLabelColor])))
            symbol?.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

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
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
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

/// The strip of formatting buttons that appears above selected text in a note.
private final class FormatBar: NSView {
    enum Action {
        case wrap(String)
        case linePrefix(String)
        case link
    }

    private let actions: [Action]
    private let onAction: (Action) -> Void

    private static let items: [(symbol: String, help: String, action: Action)] = [
        ("bold", "Жирный", .wrap("**")),
        ("italic", "Курсив", .wrap("*")),
        ("strikethrough", "Зачёркнутый", .wrap("~~")),
        ("chevron.left.forwardslash.chevron.right", "Код", .wrap("`")),
        ("link", "Ссылка", .link),
        ("textformat.size", "Заголовок", .linePrefix("## ")),
        ("list.bullet", "Список", .linePrefix("- ")),
        ("checklist", "Чек-лист", .linePrefix("- [ ] ")),
        ("text.quote", "Цитата", .linePrefix("> ")),
    ]

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        actions = Self.items.map(\.action)
        let side: CGFloat = 26
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(Self.items.count) * side + 8, height: side + 4))
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        for (index, item) in Self.items.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.help) ?? NSImage(),
                                  target: self, action: #selector(pressed(_:)))
            button.isBordered = false
            button.tag = index
            button.toolTip = item.help
            button.contentTintColor = .textBackgroundColor
            button.frame = NSRect(x: 4 + CGFloat(index) * side, y: 2, width: side, height: side)
            // A button that took the keyboard would end the selection it is meant to act on.
            button.refusesFirstResponder = true
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // The text view is flipped; without this the bar's buttons would be laid out upside down within it.
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.cgColor }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    @objc private func pressed(_ sender: NSButton) {
        onAction(actions[sender.tag])
    }
}
