import AppKit

/// A "Copy" pill that appears above text selected in the chat.
///
/// SwiftUI does not expose where a selection is, but on macOS selectable `Text` is
/// backed by a hidden text field whose field editor is a regular NSTextView, so its
/// selection notifications and geometry are available. The pill is a plain NSView on
/// top of the hosting view: clicking it never reaches SwiftUI and the selection survives.
@MainActor
final class SelectionCopyButton: NSObject {
    private weak var panel: NSPanel?
    private let pill = PillButton()
    private var monitor: Any?
    private weak var textView: NSTextView?
    private var pendingShow: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    private static let gap: CGFloat = 6

    init(panel: NSPanel) {
        self.panel = panel
        super.init()
        pill.isHidden = true
        pill.onClick = { [weak self] in self?.copy() }
        panel.contentView?.addSubview(pill)

        // Not a mouse-up monitor: while a selection is dragged the text view runs its own
        // nested tracking loop, and events consumed there never reach local monitors.
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)),
                                               name: NSTextView.didChangeSelectionNotification, object: nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                // The pill is positioned once; anything that moves or edits the text makes it stale.
                if event.window === self?.panel { self?.hide() }
            }
            return event
        }
    }

    func hide() {
        pendingShow?.cancel()
        hideTask?.cancel()
        pill.isHidden = true
    }

    @objc private func selectionChanged(_ note: Notification) {
        guard let view = note.object as? NSTextView, let panel, view.window === panel else { return }
        // The message field has its own ⌘C habits; the pill is for reading answers.
        guard !view.isEditable, view.selectedRange().length > 0 else { return hide() }
        textView = view
        pill.isHidden = true
        pendingShow?.cancel()
        pendingShow = Task { [weak self] in
            // This fires continuously during the drag; wait for the button to come up
            // so the pill does not chase the pointer.
            while NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(40))
                if Task.isCancelled { return }
            }
            self?.showAboveSelection()
        }
    }

    private func showAboveSelection() {
        guard let panel, panel.isVisible, let textView, textView.selectedRange().length > 0 else { return }
        let onScreen = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let inWindow = panel.convertFromScreen(onScreen)
        show(above: NSPoint(x: inWindow.midX, y: inWindow.maxY))
    }

    private func show(above anchor: NSPoint) {
        guard let content = panel?.contentView else { return }
        pill.setTitle("Copy")
        var origin = NSPoint(x: anchor.x - pill.frame.width / 2, y: anchor.y + Self.gap)
        origin.x = min(max(origin.x, 8), content.bounds.width - pill.frame.width - 8)
        // No room above (selection right under the header): go below the first line instead.
        if origin.y + pill.frame.height > content.bounds.height - 44 {
            origin.y = anchor.y - pill.frame.height - 24
        }
        pill.setFrameOrigin(origin)
        pill.isHidden = false
    }

    private func copy() {
        guard let textView, textView.selectedRange().length > 0 else { return hide() }
        let selected = (textView.string as NSString).substring(with: textView.selectedRange())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected, forType: .string)
        pill.setTitle("Copied ✓")
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { self?.hide() }
        }
    }
}

/// High-contrast in both appearances: text-coloured background, background-coloured text.
private final class PillButton: NSView {
    var onClick: () -> Void = {}
    private let label = NSTextField(labelWithString: "Copy")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 26))
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        addSubview(label)
        setTitle("Copy")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ title: String) {
        label.stringValue = title
        label.sizeToFit()
        setFrameSize(NSSize(width: label.frame.width + 24, height: 26))
        label.frame.origin = NSPoint(x: 12, y: (26 - label.frame.height) / 2)
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.cgColor
        label.textColor = NSColor.textBackgroundColor
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
