import AppKit
import Carbon.HIToolbox
import WinnieCore

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, ...).
    var modifiers: UInt32
    /// Human-readable form captured when the shortcut was recorded.
    var display: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_Space),
                                    modifiers: UInt32(controlKey | optionKey),
                                    display: "⌃⌥Space")
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var model: ModelOption {
        didSet { defaults.set(model.rawValue, forKey: "model") }
    }
    @Published var shortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut") }
    }

    init() {
        model = defaults.string(forKey: "model").flatMap(ModelOption.init) ?? .opus
        shortcut = defaults.data(forKey: "shortcut")
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
    }

    var petOrigin: NSPoint? {
        get {
            guard let values = defaults.array(forKey: "petOrigin") as? [Double], values.count == 2
            else { return nil }
            return NSPoint(x: values[0], y: values[1])
        }
        set { defaults.set(newValue.map { [Double($0.x), Double($0.y)] }, forKey: "petOrigin") }
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Winnie")
    }

    static var spritesDirectory: URL {
        supportDirectory.appendingPathComponent("Sprites")
    }
}
