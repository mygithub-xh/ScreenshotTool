import Cocoa
import Carbon

final class HotkeyManager {

    static let shared = HotkeyManager()
    static let defaultsKeyCode = "hotkey_keyCode"
    static let defaultsModifiers = "hotkey_modifiers"

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: 0x5352544C, id: 1)

    private var action: (() -> Void)?
    private(set) var currentKeyCode: UInt32 = 0x17
    private(set) var currentModifiers: UInt32 = UInt32(optionKey | shiftKey)

    private init() {}

    /// Register from stored preferences, falling back to defaults
    func register(action: @escaping () -> Void) -> Bool {
        self.action = action

        let savedKey = UserDefaults.standard.object(forKey: Self.defaultsKeyCode) as? UInt32
        let savedMod = UserDefaults.standard.object(forKey: Self.defaultsModifiers) as? UInt32

        currentKeyCode = savedKey ?? 0x17
        currentModifiers = savedMod ?? UInt32(optionKey | shiftKey)

        return installEventHandler() && registerHotKey(keyCode: currentKeyCode, modifiers: currentModifiers)
    }

    /// Re-register with a new key combination
    func reregister(keyCode: UInt32, modifiers: UInt32) -> Bool {
        // Unregister old
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }

        currentKeyCode = keyCode
        currentModifiers = modifiers

        // Save
        UserDefaults.standard.set(keyCode, forKey: Self.defaultsKeyCode)
        UserDefaults.standard.set(modifiers, forKey: Self.defaultsModifiers)

        return registerHotKey(keyCode: keyCode, modifiers: modifiers)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        action = nil
    }

    /// Convert NSEvent.ModifierFlags to Carbon modifier flags
    static func carbonFlags(from eventFlags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if eventFlags.contains(.command) { carbon |= UInt32(cmdKey) }
        if eventFlags.contains(.option) { carbon |= UInt32(optionKey) }
        if eventFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if eventFlags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// Human-readable description of current hotkey
    func currentHotkeyString() -> String {
        var parts: [String] = []
        let mod = currentModifiers
        if mod & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if mod & UInt32(optionKey) != 0 { parts.append("⌥") }
        if mod & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if mod & UInt32(controlKey) != 0 { parts.append("⌃") }
        // Convert key code to readable character
        if let chars = keyCodeToString(currentKeyCode) {
            parts.append(chars)
        } else {
            parts.append("?")
        }
        return parts.joined()
    }

    // MARK: - Private

    private func installEventHandler() -> Bool {
        guard eventHandler == nil else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let unmanaged = Unmanaged.passUnretained(self)
        let callback: EventHandlerProcPtr = { _, event, userData in
            guard let userData = userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

            var hkID = EventHotKeyID()
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            if err == noErr, hkID.id == 1 {
                manager.action?()
            }
            return noErr
        }

        let result = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            unmanaged.toOpaque(),
            &eventHandler
        )
        return result == noErr
    }

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let result = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return result == noErr
    }

    deinit {
        unregister()
    }
}

// MARK: - Key code conversion

func keyCodeToString(_ keyCode: UInt32) -> String? {
    // Most common key codes
    switch keyCode {
    case 0x00: return "A"
    case 0x01: return "S"
    case 0x02: return "D"
    case 0x03: return "F"
    case 0x04: return "H"
    case 0x05: return "G"
    case 0x06: return "Z"
    case 0x07: return "X"
    case 0x08: return "C"
    case 0x09: return "V"
    case 0x0B: return "B"
    case 0x0C: return "Q"
    case 0x0D: return "W"
    case 0x0E: return "E"
    case 0x0F: return "R"
    case 0x10: return "Y"
    case 0x11: return "T"
    case 0x12: return "1"
    case 0x13: return "2"
    case 0x14: return "3"
    case 0x15: return "4"
    case 0x16: return "6"
    case 0x17: return "5"
    case 0x18: return "="
    case 0x19: return "9"
    case 0x1A: return "7"
    case 0x1B: return "-"
    case 0x1C: return "8"
    case 0x1D: return "0"
    case 0x1E: return "]"
    case 0x1F: return "O"
    case 0x20: return "U"
    case 0x21: return "["
    case 0x22: return "I"
    case 0x23: return "P"
    case 0x24: return "Return"
    case 0x25: return "L"
    case 0x26: return "J"
    case 0x27: return "'"
    case 0x28: return "K"
    case 0x29: return ";"
    case 0x2A: return "\\"
    case 0x2B: return ","
    case 0x2C: return "/"
    case 0x2D: return "N"
    case 0x2E: return "M"
    case 0x2F: return "."
    case 0x32: return "`"
    case 0x41: return "."
    case 0x43: return "*"
    case 0x45: return "+"
    case 0x47: return "Clear"
    case 0x4B: return "/"
    case 0x4C: return "Enter"
    case 0x4E: return "-"
    case 0x51: return "="
    case 0x52: return "0"
    case 0x53: return "1"
    case 0x54: return "2"
    case 0x55: return "3"
    case 0x56: return "4"
    case 0x57: return "5"
    case 0x58: return "6"
    case 0x59: return "7"
    case 0x5B: return "8"
    case 0x5C: return "9"
    case 0x60: return "F5"
    case 0x61: return "F6"
    case 0x62: return "F7"
    case 0x63: return "F3"
    case 0x64: return "F8"
    case 0x65: return "F9"
    case 0x67: return "F11"
    case 0x69: return "F13"
    case 0x6A: return "F16"
    case 0x6B: return "F14"
    case 0x6D: return "F10"
    case 0x6F: return "F12"
    case 0x71: return "F15"
    case 0x72: return "Help"
    case 0x73: return "Home"
    case 0x74: return "PgUp"
    case 0x75: return "Del"
    case 0x76: return "F4"
    case 0x77: return "End"
    case 0x78: return "F2"
    case 0x79: return "PgDn"
    case 0x7A: return "F1"
    case 0x7B: return "←"
    case 0x7C: return "→"
    case 0x7D: return "↓"
    case 0x7E: return "↑"
    case 0x30: return "Tab"
    case 0x31: return "Space"
    case 0x33: return "Delete"
    case 0x35: return "Esc"
    case 0x37: return "⌘"
    case 0x38: return "⇧"
    case 0x39: return "Caps"
    case 0x3A: return "⌥"
    case 0x3B: return "⌃"
    case 0x3C: return "⇧"
    case 0x3D: return "⌥"
    case 0x3E: return "⌃"
    case 0x3F: return "Fn"
    default: return nil
    }
}
