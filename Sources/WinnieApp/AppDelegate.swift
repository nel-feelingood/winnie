import AppKit
import Combine
import SwiftUI
import WinnieCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let sprites = SpriteProvider()
    private lazy var store = ChatStore(directory: AppSettings.supportDirectory)
    private lazy var reminders = ReminderStore(directory: AppSettings.supportDirectory)
    private let gmail = GmailAuth()
    private lazy var memory = MemoryStore(directory: AppSettings.supportDirectory)
    private lazy var usage = UsageStore(directory: AppSettings.supportDirectory)
    private let mcp = MCPAuth()
    private lazy var controller = ChatController(store: store, reminders: reminders, memory: memory, usage: usage,
                                                 mcp: mcp, gmail: gmail, settings: settings)
    private var scheduler: ReminderScheduler!
    private var scaleSubscription: AnyCancellable?

    private var petWindow: PetWindow!
    private var petView: PetView!
    private var chatPanel: ChatPanel!
    private var statusMenu: StatusMenu!
    private var hotKey: HotKey!
    private var newVoiceHotKey: HotKey!
    private var settingsWindow: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        try? FileManager.default.createDirectory(at: AppSettings.spritesDirectory,
                                                 withIntermediateDirectories: true)

        petView = PetView(sprites: sprites, scale: settings.petScale)
        petView.onClick = { [unowned self] in chatPanel.isVisible ? closeChat() : openChat(new: false) }
        petView.onNewDialog = { [unowned self] in openChat(new: true) }
        petView.onMoved = { [unowned self] in
            if chatPanel.isVisible { chatPanel.position(relativeTo: petWindow.frame) }
        }
        petView.onDragEnded = { [unowned self] in settings.petOrigin = petWindow.frame.origin }
        petView.isChatOpen = { [unowned self] in chatPanel.isVisible }

        petWindow = PetWindow(scale: settings.petScale)
        petWindow.contentView = petView
        petWindow.setFrameOrigin(initialPetOrigin())
        petWindow.orderFrontRegardless()

        chatPanel = ChatPanel(content: ChatView(controller: controller, store: store))
        chatPanel.onClose = { [unowned self] in closeChat() }

        // The size can change from the settings window or from the chat ("стань побольше").
        scaleSubscription = settings.$petScale.dropFirst().removeDuplicates().sink { [unowned self] scale in
            petView.apply(scale: scale)
            settings.petOrigin = petWindow.frame.origin
            if chatPanel.isVisible { chatPanel.position(relativeTo: petWindow.frame) }
        }

        controller.onActivity = { [unowned self] in petView.setActivity($0) }
        controller.onCaptureRequest = { [unowned self] in captureScreenshot() }
        controller.onMinimize = { [unowned self] in closeChat() }
        controller.onOpenQuickActionSettings = { [unowned self] in settingsWindow.show(.quick) }
        ImageStore.removeOrphans(keeping: store.referencedImageFiles)

        settingsWindow = SettingsWindowController(
            settings: settings, gmail: gmail, memory: memory, usage: usage, mcp: mcp,
            actions: SettingsActions(
                onShortcutChange: { [unowned self] in hotKey.register($0) },
                onNewVoiceShortcutChange: { [unowned self] in newVoiceHotKey.register($0) },
                onVoicePreview: { [unowned self] in controller.previewVoice() }
            )
        )
        statusMenu = StatusMenu(settings: settings, actions: .init(
            togglePet: { [unowned self] in petWindow.isVisible ? hideEverything() : showPet() },
            newChat: { [unowned self] in openChat(new: true) },
            openSettings: { [unowned self] in settingsWindow.show() },
            reloadSprites: { [unowned self] in
                sprites.reload()
                petView.refresh()
            },
            isPetVisible: { [unowned self] in petWindow.isVisible }
        ))

        scheduler = ReminderScheduler(store: reminders)
        scheduler.onFire = { [unowned self] reminder in
            controller.present(reminder)
            showChatWithoutStealingFocus()
        }
        scheduler.onNotificationClicked = { [unowned self] in openChat(new: false) }
        scheduler.onPermissionDenied = { [unowned self] in
            controller.notify("Разреши Winnie уведомления в Системных настройках, иначе напоминания не всплывут")
        }

        // After the chat panel exists, so a reminder missed while Winnie was closed can be shown.
        scheduler.catchUp()

        hotKey = HotKey(id: 1) { [unowned self] in toggleFromShortcut() }
        hotKey.register(settings.shortcut)
        newVoiceHotKey = HotKey(id: 3) { [unowned self] in
            // Purely a microphone switch. It never starts a new dialog: whatever chat is current
            // stays current, and a closed chat is simply brought back first.
            if !chatPanel.isVisible { openChat(new: false) }
            controller.toggleListening()
        }
        newVoiceHotKey.register(settings.newVoiceShortcut)

        if !Keychain.hasAPIKey { settingsWindow.show(.api) }
    }

    // MARK: - Show / hide

    /// The shortcut is a single smart toggle: an open chat means "put it all
    /// away"; anything else means "bring Winnie and the last chat, ready to type".
    private func toggleFromShortcut() {
        chatPanel.isVisible ? hideEverything() : openChat(new: false)
    }

    private func showPet() {
        petWindow.orderFrontRegardless()
    }

    private func hideEverything() {
        closeChat()
        petWindow.orderOut(nil)
    }

    private func openChat(new: Bool) {
        showPet()
        if new { controller.newChat() } else { store.openLatest() }
        chatPanel.position(relativeTo: petWindow.frame)
        chatPanel.makeKeyAndOrderFront(nil)
        controller.focusInput()
        petView.refresh()
    }

    /// The chat steps aside so it is not in the shot, then returns with the capture attached.
    private func captureScreenshot() {
        chatPanel.isAutoCloseSuspended = true
        chatPanel.orderOut(nil)
        ScreenCapture.captureRegion { [unowned self] outcome in
            chatPanel.isAutoCloseSuspended = false
            chatPanel.position(relativeTo: petWindow.frame)
            chatPanel.makeKeyAndOrderFront(nil)
            switch outcome {
            case .captured(let file): controller.attach(file)
            case .cancelled: controller.focusInput()
            case .needsPermission:
                controller.notify("Разреши Winnie запись экрана в Системных настройках и перезапусти его")
            }
            petView.refresh()
        }
    }

    /// A reminder may arrive mid-sentence in another app: show the chat, but leave the
    /// keyboard where it is.
    private func showChatWithoutStealingFocus() {
        showPet()
        chatPanel.position(relativeTo: petWindow.frame)
        chatPanel.orderFrontRegardless()
        petView.refresh()
    }

    private func closeChat() {
        guard chatPanel.isVisible else { return }
        controller.silence()
        chatPanel.orderOut(nil)
        petView.refresh()
    }

    private func initialPetOrigin() -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let size = PetWindow.size(forScale: settings.petScale)
        let fallback = NSPoint(x: visible.maxX - size.width - 40, y: visible.minY + 20)
        guard let saved = settings.petOrigin else { return fallback }
        // A saved spot may belong to a display that is no longer connected.
        let frame = NSRect(origin: saved, size: size)
        return NSScreen.screens.contains { $0.frame.intersects(frame) } ? saved : fallback
    }

    // MARK: - Menu

    /// Invisible for an accessory app, but without it ⌘C/⌘V/⌘A never reach the
    /// chat's text fields: key equivalents are routed through the main menu.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit Winnie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let chatItem = NSMenuItem()
        chatItem.submenu = NSMenu(title: "Chat")
        let newChat = NSMenuItem(title: "New Chat", action: #selector(newChatFromMenu), keyEquivalent: "n")
        newChat.target = self
        chatItem.submenu?.addItem(newChat)
        let close = NSMenuItem(title: "Close", action: #selector(closeChatFromMenu), keyEquivalent: "w")
        close.target = self
        chatItem.submenu?.addItem(close)
        main.addItem(chatItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        // Routed through the delegate so an image on the pasteboard becomes an attachment.
        let paste = NSMenuItem(title: "Paste", action: #selector(pasteFromMenu(_:)), keyEquivalent: "v")
        paste.target = self
        edit.addItem(paste)
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    @objc private func pasteFromMenu(_ sender: Any?) {
        if chatPanel.isKeyWindow {
            let files = ImageStore.importFromPasteboard()
            if !files.isEmpty { return files.forEach(controller.attach) }
        }
        // Anything else is an ordinary paste for whichever text field has focus.
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
    }

    @objc private func newChatFromMenu() {
        if chatPanel.isVisible { controller.newChat() }
    }

    @objc private func closeChatFromMenu() {
        if chatPanel.isKeyWindow { closeChat() } else { NSApp.keyWindow?.performClose(nil) }
    }
}
