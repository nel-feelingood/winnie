import AppKit
import SwiftUI

/// The mini chat. Non-activating like Spotlight: it takes keyboard input
/// without pulling Winnie's app in front of what the user was doing.
final class ChatPanel: NSPanel {
    static let chatSize = NSSize(width: 380, height: 520)
    private static let gap: CGFloat = 8

    var onClose: () -> Void = {}
    /// Set while the panel is hidden on purpose (a screenshot in progress), so losing
    /// key status is not mistaken for the user clicking away.
    var isAutoCloseSuspended = false

    init(content: some View) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.chatSize),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true

        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        contentView = blur
        copyButton = SelectionCopyButton(panel: self)
    }

    private var copyButton: SelectionCopyButton?

    override func orderOut(_ sender: Any?) {
        copyButton?.hide()
        super.orderOut(sender)
    }

    override var canBecomeKey: Bool { true }

    /// Esc.
    override func cancelOperation(_ sender: Any?) { onClose() }

    /// Clicking anywhere else dismisses the chat.
    override func resignKey() {
        super.resignKey()
        if isVisible && !isAutoCloseSuspended { onClose() }
    }

    /// Sits above the pet when there is room, otherwise below, and never leaves the screen.
    func position(relativeTo pet: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(pet) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = Self.chatSize

        var y = pet.maxY + Self.gap
        if y + size.height > visible.maxY { y = pet.minY - Self.gap - size.height }
        y = min(max(y, visible.minY), visible.maxY - size.height)

        var x = pet.midX - size.width / 2
        // No room above or below: go beside the pet instead of covering it.
        if y < pet.maxY && y + size.height > pet.minY {
            x = pet.maxX + Self.gap
            if x + size.width > visible.maxX { x = pet.minX - Self.gap - size.width }
        }
        x = min(max(x, visible.minX), visible.maxX - size.width)

        setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }
}
