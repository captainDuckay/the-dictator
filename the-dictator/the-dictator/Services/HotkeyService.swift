import AppKit
import Carbon
import Foundation

struct HotkeyConfiguration: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let displayName: String
}

enum HotkeyServiceError: LocalizedError {
    case invalidHotkey(String)
    case registrationFailed(OSStatus)
    case eventHandlerInstallFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidHotkey(let value):
            return "Invalid hotkey format: \(value)"
        case .registrationFailed(let status):
            return "Failed to register hotkey (status \(status))."
        case .eventHandlerInstallFailed(let status):
            return "Failed to install hotkey event handler (status \(status))."
        }
    }
}

final class HotkeyService {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: HotkeyService.fourCharCode("TDCT"), id: 1)

    init() throws {
        try installEventHandler()
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func register(from setting: String) throws {
        guard let configuration = HotkeyParser.parse(setting) else {
            throw HotkeyServiceError.invalidHotkey(setting)
        }

        try register(configuration)
    }

    func register(_ configuration: HotkeyConfiguration) throws {
        unregister()

        let status = RegisterEventHotKey(
            configuration.keyCode,
            configuration.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            throw HotkeyServiceError.registrationFailed(status)
        }

        AppLogger.info(AppLogger.app, "Registered hotkey: \(configuration.displayName)")
    }

    func unregister() {
        guard let hotKeyRef else {
            return
        }

        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    private func installEventHandler() throws {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            Self.hotKeyEventHandler,
            eventTypes.count,
            &eventTypes,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )

        guard status == noErr else {
            throw HotkeyServiceError.eventHandlerInstallFailed(status)
        }
    }

    private static let hotKeyEventHandler: EventHandlerUPP = { _, eventRef, userData in
        guard let eventRef, let userData else { return noErr }

        let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()

        var eventHotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &eventHotKeyID
        )

        guard status == noErr, eventHotKeyID.id == service.hotKeyID.id else {
            return noErr
        }

        let eventKind = GetEventKind(eventRef)

        DispatchQueue.main.async {
            if eventKind == UInt32(kEventHotKeyPressed) {
                service.onKeyDown?()
            } else if eventKind == UInt32(kEventHotKeyReleased) {
                service.onKeyUp?()
            }
        }

        return noErr
    }

    private static func fourCharCode(_ string: String) -> OSType {
        var result: OSType = 0
        for scalar in string.unicodeScalars {
            result = (result << 8) + scalar.value
        }
        return result
    }
}

enum HotkeyKeyMap {
    private static let entries: [(name: String, keyCode: UInt32)] = [
        // Alphanumeric
        ("A", 0), ("S", 1), ("D", 2), ("F", 3), ("H", 4), ("G", 5), ("Z", 6), ("X", 7), ("C", 8), ("V", 9),
        ("B", 11), ("Q", 12), ("W", 13), ("E", 14), ("R", 15), ("Y", 16), ("T", 17),
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28), ("0", 29),
        ("]", 30), ("O", 31), ("U", 32), ("[", 33), ("I", 34), ("P", 35),
        ("L", 37), ("J", 38), ("'", 39), ("K", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("N", 45), ("M", 46), (".", 47), ("`", 50),

        // Controls
        ("Return", 36), ("Tab", 48), ("Space", 49), ("Delete", 51), ("Escape", 53),
        ("Forward Delete", 117), ("Home", 115), ("End", 119), ("Page Up", 116), ("Page Down", 121),
        ("Left Arrow", 123), ("Right Arrow", 124), ("Down Arrow", 125), ("Up Arrow", 126),

        // Function keys
        ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97), ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111),
        ("F13", 105), ("F14", 107), ("F15", 113), ("F16", 106), ("F17", 64), ("F18", 79), ("F19", 80), ("F20", 90),

        // Keypad
        ("Keypad 0", 82), ("Keypad 1", 83), ("Keypad 2", 84), ("Keypad 3", 85), ("Keypad 4", 86),
        ("Keypad 5", 87), ("Keypad 6", 88), ("Keypad 7", 89), ("Keypad 8", 91), ("Keypad 9", 92),
        ("Keypad Decimal", 65), ("Keypad Multiply", 67), ("Keypad Plus", 69), ("Keypad Clear", 71),
        ("Keypad Divide", 75), ("Keypad Enter", 76), ("Keypad Minus", 78), ("Keypad Equals", 81),

        // Modifiers
        ("Left Command", 55), ("Right Command", 54),
        ("Left Shift", 56), ("Right Shift", 60),
        ("Left Option", 58), ("Right Option", 61),
        ("Left Control", 59), ("Right Control", 62),
        ("Caps Lock", 57), ("Fn", 63),
    ]

    private static let nameToCode: [String: UInt32] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.name.lowercased(), $0.keyCode) }
    )

    private static let codeToName: [UInt16: String] = Dictionary(
        uniqueKeysWithValues: entries.map { (UInt16($0.keyCode), $0.name) }
    )

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static func keyCode(for keyName: String) -> UInt32? {
        let normalized = keyName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let direct = nameToCode[normalized] {
            return direct
        }

        for code in UInt16(0)...UInt16(127) {
            if let display = displayKeyName(for: code), display.lowercased() == normalized {
                return UInt32(code)
            }
        }

        return nil
    }

    static func keyName(for keyCode: UInt16) -> String? {
        displayKeyName(for: keyCode) ?? codeToName[keyCode]
    }

    static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    static func carbonModifierMask(for keyCode: UInt16) -> UInt32? {
        switch keyCode {
        case 54, 55:
            return UInt32(cmdKey)
        case 56, 60:
            return UInt32(shiftKey)
        case 58, 61:
            return UInt32(optionKey)
        case 59, 62:
            return UInt32(controlKey)
        default:
            return nil
        }
    }

    static func modifierGroup(for keyName: String) -> String? {
        let normalized = keyName.lowercased()
        if normalized.contains("shift") { return "shift" }
        if normalized.contains("option") { return "option" }
        if normalized.contains("control") { return "control" }
        if normalized.contains("command") { return "command" }
        return nil
    }

    private static func displayKeyName(for keyCode: UInt16) -> String? {
        if let fixed = codeToName[keyCode], isFixedLabelPreferred(fixed) {
            return fixed
        }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }

        let layoutData = unsafeBitCast(rawLayoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }

        let keyboardLayout = UnsafePointer<UCKeyboardLayout>(OpaquePointer(bytes))
        var deadKeyState: UInt32 = 0
        let maxLength = 4
        var actualLength = 0
        var chars = [UniChar](repeating: 0, count: maxLength)

        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            maxLength,
            &actualLength,
            &chars
        )

        guard status == noErr, actualLength > 0 else {
            return nil
        }

        let raw = String(utf16CodeUnits: chars, count: actualLength)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !raw.isEmpty else {
            return nil
        }

        return raw.uppercased()
    }

    private static func isFixedLabelPreferred(_ label: String) -> Bool {
        label.contains("Arrow") ||
        label.hasPrefix("F") ||
        label.hasPrefix("Keypad") ||
        ["Return", "Tab", "Space", "Delete", "Escape", "Forward Delete", "Home", "End", "Page Up", "Page Down", "Caps Lock", "Fn"].contains(label)
    }
}

enum HotkeyDisplay {
    static func modifierNames(from flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.command) { names.append("Command") }
        if flags.contains(.option) { names.append("Option") }
        if flags.contains(.control) { names.append("Control") }
        if flags.contains(.shift) { names.append("Shift") }
        return names
    }

    static func modifierNames(fromCarbonModifiers modifiers: UInt32) -> [String] {
        var names: [String] = []
        if modifiers & UInt32(cmdKey) != 0 { names.append("Command") }
        if modifiers & UInt32(optionKey) != 0 { names.append("Option") }
        if modifiers & UInt32(controlKey) != 0 { names.append("Control") }
        if modifiers & UInt32(shiftKey) != 0 { names.append("Shift") }
        return names
    }

    static func format(modifiers: [String], keyName: String) -> String {
        let filteredModifiers = modifiers.filter { modifier in
            guard let keyGroup = HotkeyKeyMap.modifierGroup(for: keyName) else { return true }
            return modifier.lowercased() != keyGroup
        }

        if filteredModifiers.isEmpty {
            return keyName
        }

        return (filteredModifiers + [keyName]).joined(separator: " + ")
    }
}

enum HotkeyParser {
    private static let storagePrefix = "hk2"

    static func parse(_ raw: String) -> HotkeyConfiguration? {
        if let serialized = parseSerialized(raw) {
            let keyCode = UInt16(serialized.keyCode)
            let keyName = HotkeyKeyMap.keyName(for: keyCode) ?? "Key \(serialized.keyCode)"
            let displayName = HotkeyDisplay.format(
                modifiers: HotkeyDisplay.modifierNames(fromCarbonModifiers: serialized.modifiers),
                keyName: keyName
            )

            return HotkeyConfiguration(keyCode: serialized.keyCode, modifiers: serialized.modifiers, displayName: displayName)
        }

        let parts = raw
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let keyPart = parts.last else { return nil }
        guard let keyCode = HotkeyKeyMap.keyCode(for: keyPart) else { return nil }

        var modifiers: UInt32 = 0

        for modifierPart in parts.dropLast() {
            switch modifierPart.lowercased() {
            case "shift":
                modifiers |= UInt32(shiftKey)
            case "option", "alt":
                modifiers |= UInt32(optionKey)
            case "command", "cmd":
                modifiers |= UInt32(cmdKey)
            case "control", "ctrl":
                modifiers |= UInt32(controlKey)
            default:
                return nil
            }
        }

        if let selfMask = HotkeyKeyMap.carbonModifierMask(for: UInt16(keyCode)) {
            modifiers &= ~selfMask
        }

        let displayName = displayName(forStoredValue: raw)
        return HotkeyConfiguration(keyCode: keyCode, modifiers: modifiers, displayName: displayName)
    }

    static func serialize(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> String? {
        var modifiers = carbonModifiers(from: modifierFlags)

        if let selfMask = HotkeyKeyMap.carbonModifierMask(for: keyCode) {
            modifiers &= ~selfMask
        }

        return "\(storagePrefix):\(keyCode):\(modifiers)"
    }

    static func displayName(forStoredValue raw: String) -> String {
        if let serialized = parseSerialized(raw) {
            let keyName = HotkeyKeyMap.keyName(for: UInt16(serialized.keyCode)) ?? "Key \(serialized.keyCode)"
            return HotkeyDisplay.format(
                modifiers: HotkeyDisplay.modifierNames(fromCarbonModifiers: serialized.modifiers),
                keyName: keyName
            )
        }

        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseSerialized(_ raw: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Substring(storagePrefix),
              let keyCode = UInt32(parts[1]),
              let modifiers = UInt32(parts[2])
        else {
            return nil
        }

        return (keyCode: keyCode, modifiers: modifiers)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        let normalized = flags.intersection([.command, .option, .control, .shift])
        if normalized.contains(.command) { result |= UInt32(cmdKey) }
        if normalized.contains(.option) { result |= UInt32(optionKey) }
        if normalized.contains(.control) { result |= UInt32(controlKey) }
        if normalized.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
