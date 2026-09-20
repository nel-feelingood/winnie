import AppKit
import WinnieCore

/// The always-on-top pet. A non-activating panel so clicking Winnie never
/// steals focus from the app the user is working in.
final class PetWindow: NSPanel {
    static let petSize = NSSize(width: 150, height: 190)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.petSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
}

@MainActor
final class PetView: NSView {
    var onClick: () -> Void = {}
    var onNewDialog: () -> Void = {}
    var onDragEnded: () -> Void = {}
    var onMoved: () -> Void = {}
    /// The "New dialog" button only makes sense while the chat is closed.
    var isChatOpen: () -> Bool = { false }

    private let sprites: SpriteProvider
    private let spriteLayer = CALayer()
    private let newDialogButton = NSButton()
    private var mood = PetMood()
    private var dragStart: NSPoint?
    private var windowStart: NSPoint = .zero
    private var sleepTimer: Timer?

    private static let dragThreshold: CGFloat = 4
    private static let sleepDelay: TimeInterval = 5 * 60

    init(sprites: SpriteProvider) {
        self.sprites = sprites
        super.init(frame: NSRect(origin: .zero, size: PetWindow.petSize))
        wantsLayer = true

        // Anchored at the feet so the breathing scale grows upward.
        spriteLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        spriteLayer.frame = NSRect(x: 0, y: 0, width: 150, height: 150)
        spriteLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(spriteLayer)

        newDialogButton.title = "New dialog"
        newDialogButton.bezelStyle = .rounded
        newDialogButton.controlSize = .small
        newDialogButton.font = .systemFont(ofSize: 11, weight: .medium)
        newDialogButton.target = self
        newDialogButton.action = #selector(newDialogPressed)
        newDialogButton.sizeToFit()
        newDialogButton.frame.origin = NSPoint(x: (bounds.width - newDialogButton.frame.width) / 2,
                                               y: bounds.height - newDialogButton.frame.height - 6)
        newDialogButton.isHidden = true
        addSubview(newDialogButton)

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        render()
        restartSleepTimer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - State

    func setActivity(_ activity: ChatActivity) {
        mood.activity = activity
        wake()
        render()
    }

    func refresh() {
        newDialogButton.isHidden = !mood.isHovering || isChatOpen()
        render()
    }

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = sprites.image(for: mood.state)
        CATransaction.commit()
        updateBreathing()
    }

    /// A slow Core Animation scale: composited on the GPU, no per-frame app code,
    /// so it costs next to nothing. Stopped while asleep or dragged.
    private func updateBreathing() {
        let shouldBreathe = mood.state != .sleep && mood.state != .drag
        let isBreathing = spriteLayer.animation(forKey: "breathe") != nil
        guard shouldBreathe != isBreathing else { return }
        guard shouldBreathe else { return spriteLayer.removeAnimation(forKey: "breathe") }
        let breathe = CABasicAnimation(keyPath: "transform.scale.y")
        breathe.fromValue = 1.0
        breathe.toValue = 1.025
        breathe.duration = 2.2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        spriteLayer.add(breathe, forKey: "breathe")
    }

    private func wake() {
        mood.isAsleep = false
        restartSleepTimer()
    }

    private func restartSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(withTimeInterval: Self.sleepDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mood.isAsleep = true
                self?.render()
            }
        }
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        mood.isHovering = true
        wake()
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        mood.isHovering = false
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let window else { return }
        let now = NSEvent.mouseLocation
        let delta = NSPoint(x: now.x - dragStart.x, y: now.y - dragStart.y)
        if !mood.isDragging {
            guard hypot(delta.x, delta.y) > Self.dragThreshold else { return }
            mood.isDragging = true
            newDialogButton.isHidden = true
            render()
        }
        window.setFrameOrigin(NSPoint(x: windowStart.x + delta.x, y: windowStart.y + delta.y))
        onMoved()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        wake()
        if mood.isDragging {
            mood.isDragging = false
            refresh()
            onDragEnded()
        } else {
            onClick()
        }
    }

    @objc private func newDialogPressed() {
        onNewDialog()
    }
}
