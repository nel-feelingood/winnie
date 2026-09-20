import AppKit
import WinnieCore

/// The always-on-top pet. A non-activating panel so clicking Winnie never
/// steals focus from the app the user is working in.
final class PetWindow: NSPanel {
    /// Sprite edge at 100% scale, in points.
    static let baseSpriteSide: CGFloat = 150
    /// Strip above the sprite where the "New dialog" button appears.
    static let buttonStrip: CGFloat = 40
    /// The button keeps its size at any scale, so the window never gets narrower than it.
    static let minimumWidth: CGFloat = 110

    static func size(forScale scale: Double) -> NSSize {
        let side = (baseSpriteSide * scale).rounded()
        return NSSize(width: max(side, minimumWidth), height: side + buttonStrip)
    }

    init(scale: Double) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size(forScale: scale)),
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
    private static let sleepDelay: TimeInterval = 60

    init(sprites: SpriteProvider, scale: Double) {
        self.sprites = sprites
        super.init(frame: NSRect(origin: .zero, size: PetWindow.size(forScale: scale)))
        wantsLayer = true
        autoresizingMask = [.width, .height]

        // Anchored at the feet so the breathing scale grows upward.
        spriteLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        spriteLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(spriteLayer)

        newDialogButton.title = "New dialog"
        newDialogButton.bezelStyle = .rounded
        newDialogButton.controlSize = .small
        newDialogButton.font = .systemFont(ofSize: 11, weight: .medium)
        newDialogButton.target = self
        newDialogButton.action = #selector(newDialogPressed)
        newDialogButton.sizeToFit()
        newDialogButton.isHidden = true
        addSubview(newDialogButton)
        layoutContents()

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        render()
        restartSleepTimer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    /// Resizes the pet around its feet, so scaling never makes Winnie slide sideways or sink.
    func apply(scale: Double) {
        guard let window else { return }
        let size = PetWindow.size(forScale: scale)
        let old = window.frame
        let origin = NSPoint(x: old.midX - size.width / 2, y: old.minY)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        layoutContents()
    }

    private func layoutContents() {
        let side = bounds.height - PetWindow.buttonStrip
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        spriteLayer.position = CGPoint(x: bounds.midX, y: 0)
        CATransaction.commit()
        newDialogButton.frame.origin = NSPoint(x: (bounds.width - newDialogButton.frame.width) / 2,
                                               y: bounds.height - newDialogButton.frame.height - 6)
    }

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

    private enum Breathing: Equatable {
        case none, awake, asleep

        /// Peak vertical stretch and the length of one inhale, in seconds.
        var shape: (scale: CGFloat, inhale: CFTimeInterval)? {
            switch self {
            case .none: nil
            case .awake: (1.025, 2.2)
            // Sleep is slower and deeper, so it reads as snoozing rather than standing.
            case .asleep: (1.04, 3.4)
            }
        }
    }

    private var breathing = Breathing.none

    /// A slow Core Animation scale: composited by the window server with no
    /// per-frame app code, so it costs next to nothing even running all day.
    private func updateBreathing() {
        let wanted: Breathing = switch mood.state {
        case .drag: .none
        case .sleep: .asleep
        default: .awake
        }
        guard wanted != breathing else { return }
        breathing = wanted
        spriteLayer.removeAnimation(forKey: "breathe")
        guard let shape = wanted.shape else { return }
        let breathe = CABasicAnimation(keyPath: "transform.scale.y")
        breathe.fromValue = 1.0
        breathe.toValue = shape.scale
        breathe.duration = shape.inhale
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
