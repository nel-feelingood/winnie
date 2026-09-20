import AppKit
import os

/// A "Copy" pill that appears above text selected in the chat.
///
/// SwiftUI does not expose where a selection is, so this works at the AppKit level:
/// after a mouse-up it asks the panel's first responder. The pill is a plain NSView
/// on top of the hosting view, so clicking it never reaches SwiftUI and the
/// selection survives the click.
@MainActor
final class SelectionCopyButton: NSObject {
    private weak var panel: NSPanel?
    private let pill = PillButton()
    private var monitor: Any?
    /// Set when the selection lives in a real NSTextView; otherwise copying goes
    /// through the responder chain, exactly like pressing ⌘C.
    private weak var textView: NSTextView?
    private var hideTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "local.winnie.pet", category: "selection")
    private static let gap: CGFloat = 6

    init(panel: NSPanel) {
        self.panel = panel
        super.init()
        pill.isHidden = true
        pill.onClick = { [weak self] in self?.copy() }
        panel.contentView?.addSubview(pill)

        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .scrollWheel, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func hide() {
        hideTask?.cancel()
        pill.isHidden = true
        textView = nil
    }

    private func handle(_ event: NSEvent) {
        guard let panel, event.window === panel else { return }
        switch event.type {
        case .leftMouseUp:
            let location = event.locationInWindow
            guard !pill.frame.contains(location) else { return }
            // The selection is final only after the text view has processed this mouse-up.
            DispatchQueue.main.async { [weak self] in self?.evaluate(mouseUpAt: location) }
        case .leftMouseDown:
            if !pill.frame.contains(event.locationInWindow) { hide() }
        default:
            hide()
        }
    }

    private func evaluate(mouseUpAt location: NSPoint) {
        guard let panel, panel.isVisible else { return }

        if let view = panel.firstResponder as? NSTextView {
            // The message field has its own ⌘C habits; the pill is for reading answers.
            guard !view.isEditable, view.selectedRange().length > 0 else { return hide() }
            textView = view
            let onScreen = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
            let inWindow = panel.convertFromScreen(onScreen)
            Self.log.notice("selection in NSTextView")
            return show(above: NSPoint(x: inWindow.midX, y: inWindow.maxY))
        }

        // No NSTextView: fall back to "can something copy right now?" and anchor to the pointer.
        let item = NSMenuItem(title: "", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        guard let target = NSApp.target(forAction: #selector(NSText.copy(_:)), to: nil, from: item),
              (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? false
        else { return hide() }
        Self.log.notice("selection via responder chain: \(String(describing: type(of: target)), privacy: .public)")
        show(above: NSPoint(x: location.x, y: location.y + 10))
    }

    private func show(above anchor: NSPoint) {
        guard let content = panel?.contentView else { return }
        pill.setTitle("Copy")
        var origin = NSPoint(x: anchor.x - pill.frame.width / 2, y: anchor.y + Self.gap)
        origin.x = min(max(origin.x, 8), content.bounds.width - pill.frame.width - 8)
        // No room above (selection at the very top): go below the pointer instead of off-panel.
        if origin.y + pill.frame.height > content.bounds.height - 44 {
            origin.y = anchor.y - pill.frame.height - 28
        }
        pill.setFrameOrigin(origin)
        pill.isHidden = false
    }

    private func copy() {
        if let textView {
            let selected = (textView.string as NSString).substring(with: textView.selectedRange())
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selected, forType: .string)
        } else {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        }
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
