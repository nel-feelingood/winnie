import AppKit
import Carbon.HIToolbox

/// System-wide shortcut via Carbon. Unlike an NSEvent global monitor, this
/// needs no Accessibility permission and swallows the keystroke.
@MainActor
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        let spec = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, spec, context, &handlerRef)
    }

    func register(_ shortcut: Shortcut) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        let id = EventHotKeyID(signature: OSType(0x574E_4E45), id: 1) // 'WNNE'
        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

extension Shortcut {
    /// Builds a shortcut from a recorded key press; nil unless a modifier is held,
    /// so a bare letter can never be captured system-wide.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        guard carbon & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }

        let key: String
        switch Int(event.keyCode) {
        case kVK_Space: key = "Space"
        case kVK_Return: key = "↩"
        case kVK_Escape: return nil
        default: key = (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, display: symbols + key)
    }
}
