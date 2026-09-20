import AppKit
import WinnieCore

/// The always-on-top pet. A non-activating panel so clicking Winnie never
/// steals focus from the app the user is working in.
final class PetWindow: NSPanel {
    /// Sprite edge at 100% scale, in points.
    static let baseSpriteSide: CGFloat = 150
    /// Strip above the sprite where the "New dialog" button appears.
    static let buttonStrip: CGFloat = 44
    /// The button keeps its size at any scale, so the window never gets narrower than it.
    static let minimumWidth: CGFloat = 130

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
    private let newDialogButton = PillButton(title: "New dialog", fontSize: 13, height: 30)
    private var mood = PetMood()
    private var dragStart: NSPoint?
    private var windowStart: NSPoint = .zero
    private var sleepTimer: Timer?
    private var smokeTimer: Timer?
    private var dreamTimer: Timer?
    private let dreamLayer = CALayer()
    /// Asked each time, so the settings toggle takes effect without a restart.
    var dreamsEnabled: () -> Bool = { true }

    private static let dreamInterval: TimeInterval = 10
    private static let dreamDuration: CFTimeInterval = 3
    /// Every single-character emoji this Mac can draw: taken from the Unicode tables rather than a
    /// hand-picked list, and checked against the emoji font so that none comes out as an empty box.
    /// Flags, skin-tone modifiers and multi-person sequences are several characters each and are left out.
    private static let dreams: [String] = {
        let font = CTFontCreateWithName("Apple Color Emoji" as CFString, 24, nil)
        return (0x231A...0x1FAFF).compactMap { Unicode.Scalar($0) }.filter { scalar in
            guard scalar.properties.isEmojiPresentation, !scalar.properties.isEmojiModifier,
                  !(0x1F1E6...0x1F1FF).contains(scalar.value) else { return false }
            var characters = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            return CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) && glyphs[0] != 0
        }.map { String($0) }
    }()
    private var smokeFrames: [NSImage] = []
    private var smokeIndex = 0

    /// Seconds each frame of the smoke break stays on screen.
    private static let smokeFrameDuration: TimeInterval = 0.7

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
        dreamLayer.opacity = 0
        dreamLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(dreamLayer)

        newDialogButton.onClick = { [unowned self] in onNewDialog() }
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
                                               y: bounds.height - newDialogButton.frame.height - 8)
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

    // MARK: - Dreams

    /// One timer tick every ten seconds, and only while asleep; the fade itself is a Core
    /// Animation, so between ticks the app does nothing.
    private func updateDreams() {
        let shouldDream = mood.state == .sleep
        guard shouldDream != (dreamTimer != nil) else { return }
        dreamTimer?.invalidate()
        dreamTimer = nil
        guard shouldDream else {
            dreamLayer.removeAllAnimations()
            return
        }
        dreamTimer = Timer.scheduledTimer(withTimeInterval: Self.dreamInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showDream() }
        }
    }

    private func showDream() {
        guard dreamsEnabled(), mood.state == .sleep, let emoji = Self.dreams.randomElement() else { return }
        let spriteSide = bounds.height - PetWindow.buttonStrip
        let size = max(22, spriteSide * 0.2)
        // Just above the sleeping head (he sits lower than he stands), a little off-centre each time.
        let start = CGPoint(x: bounds.midX + CGFloat.random(in: -0.12...0.12) * spriteSide, y: spriteSide * 0.9 + size / 2)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dreamLayer.contents = Self.image(of: emoji, side: size * 2)
        dreamLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dreamLayer.position = start
        CATransaction.commit()

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.25, 0.7, 1]
        let rise = CABasicAnimation(keyPath: "position.y")
        rise.fromValue = start.y
        rise.toValue = start.y + size * 0.6
        let group = CAAnimationGroup()
        group.animations = [fade, rise]
        group.duration = Self.dreamDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dreamLayer.add(group, forKey: "dream")
    }

    /// Emoji are drawn into an image: colour glyphs render reliably that way on any layer.
    private static func image(of emoji: String, side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: side * 0.78)])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }

    // MARK: - Smoke break

    /// Plays `smoke-0…N` once. While it runs it owns the sprite: hovering, dragging and chat
    /// activity still update the mood underneath, and whatever state is current takes over
    /// when the last frame is done.
    func playSmokeBreak() {
        let frames = sprites.frames(named: "smoke")
        guard !frames.isEmpty, !mood.isOnSmokeBreak else { return }
        smokeFrames = frames
        smokeIndex = 0
        mood.isOnSmokeBreak = true
        wake()
        show(frames[0])
        smokeTimer = Timer.scheduledTimer(withTimeInterval: Self.smokeFrameDuration, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceSmokeBreak() }
        }
    }

    private func advanceSmokeBreak() {
        smokeIndex += 1
        guard smokeIndex < smokeFrames.count else {
            smokeTimer?.invalidate()
            smokeTimer = nil
            smokeFrames = []
            mood.isOnSmokeBreak = false
            return render()
        }
        show(smokeFrames[smokeIndex])
    }

    private func show(_ image: NSImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = image
        CATransaction.commit()
    }

    private func render() {
        // The running animation sets frames itself; a state change must not paint over them.
        guard mood.state != .smoke else { return updateBreathing() }
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
        updateDreams()
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

}
