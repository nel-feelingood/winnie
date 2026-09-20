import AppKit

/// A fully rounded button used for the floating actions (Copy, New dialog).
/// High-contrast in both appearances: text-coloured background, background-coloured text.
final class PillButton: NSView {
    var onClick: () -> Void = {}

    private let label = NSTextField(labelWithString: "")
    private let height: CGFloat
    private let sidePadding: CGFloat

    init(title: String, fontSize: CGFloat, height: CGFloat) {
        self.height = height
        sidePadding = (height / 2).rounded()
        super.init(frame: NSRect(x: 0, y: 0, width: height * 2, height: height))
        wantsLayer = true
        layer?.cornerRadius = height / 2
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        label.font = .systemFont(ofSize: fontSize, weight: .semibold)
        label.alignment = .center
        addSubview(label)
        setTitle(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ title: String) {
        label.stringValue = title
        label.sizeToFit()
        setFrameSize(NSSize(width: label.frame.width + sidePadding * 2, height: height))
        label.frame.origin = NSPoint(x: sidePadding, y: ((height - label.frame.height) / 2).rounded())
    }

    override func updateLayer() {
        layer?.backgroundColor = (isPressed ? NSColor.secondaryLabelColor : NSColor.labelColor).cgColor
        label.textColor = NSColor.textBackgroundColor
    }

    private var isPressed = false { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
