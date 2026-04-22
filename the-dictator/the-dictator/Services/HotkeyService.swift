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

enum HotkeyParser {
    private static let keyCodes: [String: UInt32] = [
        "Right Option": 61,
        "Left Option": 58,
        "Space": 49,
        "F8": 100,
        "F7": 98,
        "F6": 97,
    ]

    static func parse(_ raw: String) -> HotkeyConfiguration? {
        let parts = raw
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let keyPart = parts.last else { return nil }
        guard let keyCode = keyCodes[keyPart] else { return nil }

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

        return HotkeyConfiguration(keyCode: keyCode, modifiers: modifiers, displayName: raw)
    }
}
