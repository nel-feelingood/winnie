import AppKit
import WinnieCore

/// Supplies the image for each pet state. Real sprites are PNGs dropped into
/// the Sprites folder; until they exist a drawn stand-in keeps the app usable.
@MainActor
final class SpriteProvider {
    private var cache: [PetState: NSImage] = [:]

    func image(for state: PetState) -> NSImage {
        if let cached = cache[state] { return cached }
        // Until a dedicated `listening.png` is drawn, the attentive hover pose stands in for it.
        let standIn = state == .listening ? load(.hover) : nil
        let image = load(state) ?? standIn ?? load(.idle) ?? Self.placeholder(for: state)
        cache[state] = image
        return image
    }

    func reload() { cache.removeAll() }

    /// Frames of a sequence, `<name>-0.png`, `<name>-1.png`, … up to the first gap.
    func frames(named name: String) -> [NSImage] {
        var frames: [NSImage] = []
        while let frame = NSImage(contentsOf: AppSettings.spritesDirectory.appendingPathComponent("\(name)-\(frames.count).png")) {
            frames.append(frame)
        }
        return frames
    }

    var hasCustomSprites: Bool { load(.idle) != nil }

    private func load(_ state: PetState) -> NSImage? {
        let url = AppSettings.spritesDirectory.appendingPathComponent("\(state.rawValue).png")
        return NSImage(contentsOf: url)
    }

    private static func placeholder(for state: PetState) -> NSImage {
        let size = NSSize(width: 256, height: 256)
        return NSImage(size: size, flipped: false) { _ in
            let fur = NSColor(red: 0.36, green: 0.22, blue: 0.13, alpha: 1)
            let dark = NSColor(red: 0.16, green: 0.09, blue: 0.05, alpha: 1)
            let muzzle = NSColor(red: 0.78, green: 0.62, blue: 0.44, alpha: 1)

            dark.setFill()
            NSBezierPath(ovalIn: NSRect(x: 48, y: 176, width: 48, height: 48)).fill()
            NSBezierPath(ovalIn: NSRect(x: 160, y: 176, width: 48, height: 48)).fill()
            NSBezierPath(ovalIn: NSRect(x: 70, y: 8, width: 44, height: 30)).fill()
            NSBezierPath(ovalIn: NSRect(x: 142, y: 8, width: 44, height: 30)).fill()
            fur.setFill()
            NSBezierPath(ovalIn: NSRect(x: 40, y: 20, width: 176, height: 196)).fill()
            muzzle.setFill()
            NSBezierPath(ovalIn: NSRect(x: 88, y: 96, width: 80, height: 60)).fill()
            dark.setFill()
            NSBezierPath(ovalIn: NSRect(x: 112, y: 128, width: 32, height: 22)).fill()

            let face: String
            switch state {
            case .idle: face = "• •"
            case .hover, .listening, .smoke: face = "◉ ◉"
            case .thinking: face = "• ˙"
            case .talking: face = "• •"
            case .drag: face = "° °"
            case .error: face = "× ×"
            case .sleep: face = "– –"
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 30, weight: .heavy),
                .foregroundColor: NSColor.white,
            ]
            let text = NSAttributedString(string: face, attributes: attributes)
            text.draw(at: NSPoint(x: 128 - text.size().width / 2, y: 156))
            if state == .talking || state == .drag {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 118, y: 102, width: 20, height: 16)).fill()
            }
            return true
        }
    }
}
