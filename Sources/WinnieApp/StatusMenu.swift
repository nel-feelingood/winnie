import AppKit
import ServiceManagement
import WinnieCore

/// Winnie's vector silhouette, shared by the menu bar and the settings sidebar.
@MainActor
enum WinnieIcon {
    /// A template image: only its shape matters, macOS tints it for light and dark
    /// surroundings, so the white fill of the source SVG is irrelevant.
    static func template(side: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "menubar", withExtension: "svg"),
              let icon = NSImage(contentsOf: url)?.copy() as? NSImage else {
            // Running outside the .app bundle (swift run): keep a recognisable stand-in.
            return NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Winnie")
        }
        icon.size = NSSize(width: side, height: side)
        icon.isTemplate = true
        icon.accessibilityDescription = "Winnie"
        return icon
    }
}

/// Winnie's menu in the menu bar, next to the clock.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    struct Actions {
        var togglePet: () -> Void
        var newChat: () -> Void
        var openSettings: () -> Void
        var reloadSprites: () -> Void
        var isPetVisible: () -> Bool
    }

    private let item: NSStatusItem
    private let settings: AppSettings
    private let actions: Actions

    init(settings: AppSettings, actions: Actions) {
        self.settings = settings
        self.actions = actions
        item = Self.makeStatusItem()
        super.init()
        item.button?.image = WinnieIcon.template(side: 18)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// New status items are added at the far left, and on a notched MacBook with a full
    /// menu bar that spot is behind the notch, where macOS silently hides the item.
    /// Seeding the position macOS itself persists (points from the right edge) starts
    /// Winnie among the visible items; after that the user's own ⌘-drag wins.
    private static func makeStatusItem() -> NSStatusItem {
        let name = "WinnieStatusItem"
        let positionKey = "NSStatusItem Preferred Position \(name)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(330.0, forKey: positionKey)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = name
        return item
    }

    /// Rebuilt on every open so titles and checkmarks always reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let toggleTitle = actions.isPetVisible() ? "Спрятать Винни" : "Показать Винни"
        menu.addItem(make("\(toggleTitle)   \(settings.shortcut.display)", #selector(togglePet)))
        menu.addItem(make("Новый чат", #selector(newChat)))
        menu.addItem(.separator())

        let models = NSMenuItem(title: "Модель", action: nil, keyEquivalent: "")
        models.submenu = NSMenu()
        for option in ModelOption.allCases {
            let entry = make(option.displayName, #selector(pickModel(_:)))
            entry.representedObject = option.rawValue
            entry.state = option == settings.model ? .on : .off
            models.submenu?.addItem(entry)
        }
        menu.addItem(models)
        menu.addItem(make("Настройки…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(make("Открыть папку спрайтов", #selector(openSprites)))
        menu.addItem(make("Перезагрузить спрайты", #selector(reloadSprites)))

        let login = make("Запускать при входе", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(make("Выйти", #selector(quit)))
    }

    private func make(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func togglePet() { actions.togglePet() }
    @objc private func newChat() { actions.newChat() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func reloadSprites() { actions.reloadSprites() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = ModelOption(rawValue: raw) else { return }
        settings.model = option
    }

    @objc private func openSprites() {
        let directory = AppSettings.spritesDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        if service.status == .enabled { try? service.unregister() } else { try? service.register() }
    }
}
