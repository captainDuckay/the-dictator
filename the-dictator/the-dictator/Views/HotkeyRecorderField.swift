import AppKit
import SwiftUI

struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var value: String
    let placeholder: String

    func makeNSView(context: Context) -> HotkeyCaptureTextField {
        let field = HotkeyCaptureTextField()
        field.placeholderString = placeholder
        field.onCapture = { captured in
            value = captured
        }
        field.updateDisplay(value)
        return field
    }

    func updateNSView(_ nsView: HotkeyCaptureTextField, context: Context) {
        nsView.onCapture = { captured in
            value = captured
        }
        nsView.updateDisplay(value)
    }
}

final class HotkeyCaptureTextField: NSTextField {
    var onCapture: ((String) -> Void)?

    private var representedValue: String = ""
    private var capturedDuringCurrentFocus = false
    private var localEventMonitor: Any?
    private var isCapturing = false
    private var pendingModifierOnlyKeyCode: UInt16?
    private var sawNonModifierKeyDuringCurrentFocus = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        removeLocalEventMonitor()
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        _ = window?.makeFirstResponder(self)
        startCaptureSession()
    }

    func updateDisplay(_ value: String) {
        representedValue = value
        guard !isCapturing else { return }
        stringValue = HotkeyParser.displayName(forStoredValue: value)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            startCaptureSession()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            stopCaptureSession(restoreDisplay: true)
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        if isCapturing {
            handleKeyDown(event)
        } else {
            super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if isCapturing {
            handleFlagsChanged(event)
        } else {
            super.flagsChanged(with: event)
        }
    }

    private func configure() {
        isEditable = false
        isSelectable = false
        isEnabled = true
        isBordered = true
        focusRingType = .default
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: NSFont.systemFontSize)
    }

    private func startCaptureSession() {
        capturedDuringCurrentFocus = false
        isCapturing = true
        pendingModifierOnlyKeyCode = nil
        sawNonModifierKeyDuringCurrentFocus = false
        stringValue = "Press shortcut…"
        installLocalEventMonitor()
    }

    private func stopCaptureSession(restoreDisplay: Bool) {
        removeLocalEventMonitor()
        isCapturing = false
        capturedDuringCurrentFocus = false
        pendingModifierOnlyKeyCode = nil
        sawNonModifierKeyDuringCurrentFocus = false

        if restoreDisplay {
            stringValue = HotkeyParser.displayName(forStoredValue: representedValue)
        }
    }

    private func installLocalEventMonitor() {
        removeLocalEventMonitor()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }

            switch event.type {
            case .keyDown:
                guard self.window?.firstResponder === self, self.isCapturing else { return event }
                self.handleKeyDown(event)
                return nil

            case .flagsChanged:
                guard self.window?.firstResponder === self, self.isCapturing else { return event }
                self.handleFlagsChanged(event)
                return nil

            case .leftMouseDown, .rightMouseDown:
                guard self.isCapturing else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) {
                    self.stopCaptureSession(restoreDisplay: true)
                }
                return event

            default:
                return event
            }
        }
    }

    private func removeLocalEventMonitor() {
        guard let localEventMonitor else { return }
        NSEvent.removeMonitor(localEventMonitor)
        self.localEventMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) {
        sawNonModifierKeyDuringCurrentFocus = true
        pendingModifierOnlyKeyCode = nil

        guard let serialized = HotkeyParser.serialize(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) else {
            NSSound.beep()
            return
        }

        commitCapture(serialized)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard !capturedDuringCurrentFocus else { return }

        let activeModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if let pendingModifierOnlyKeyCode,
           activeModifiers.isEmpty,
           !sawNonModifierKeyDuringCurrentFocus,
           let serialized = HotkeyParser.serialize(keyCode: pendingModifierOnlyKeyCode, modifierFlags: []) {
            commitCapture(serialized)
            return
        }

        guard !sawNonModifierKeyDuringCurrentFocus else { return }
        guard HotkeyKeyMap.isModifierKeyCode(event.keyCode) else { return }
        guard !activeModifiers.isEmpty else { return }

        pendingModifierOnlyKeyCode = event.keyCode
    }

    private func commitCapture(_ value: String) {
        representedValue = value
        stringValue = HotkeyParser.displayName(forStoredValue: value)
        capturedDuringCurrentFocus = true
        onCapture?(value)

        stopCaptureSession(restoreDisplay: false)

        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(nil)
        }
    }
}
