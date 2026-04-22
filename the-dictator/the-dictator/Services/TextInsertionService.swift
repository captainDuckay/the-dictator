import AppKit
import ApplicationServices
import Foundation

enum TextInsertionError: LocalizedError {
    case accessibilityPermissionMissing
    case noActiveTarget
    case clipboardWriteFailed
    case failedToCreatePasteEvents
    case pasteLikelyFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required for paste injection."
        case .noActiveTarget:
            return "No active target app was found for text insertion."
        case .clipboardWriteFailed:
            return "Failed to place transcript on the clipboard."
        case .failedToCreatePasteEvents:
            return "Failed to create paste keyboard events."
        case .pasteLikelyFailed:
            return "Paste likely failed. Use Paste Last Transcript to retry."
        }
    }
}

private struct TargetContext {
    let processID: pid_t
}

@MainActor
final class TextInsertionService {
    private let clipboardService: ClipboardService
    private let verificationDelayNanoseconds: UInt64

    init(
        clipboardService: ClipboardService,
        verificationDelayNanoseconds: UInt64
    ) {
        self.clipboardService = clipboardService
        self.verificationDelayNanoseconds = verificationDelayNanoseconds
    }

    convenience init() {
        self.init(
            clipboardService: ClipboardService(),
            verificationDelayNanoseconds: 650_000_000
        )
    }

    func insert(text: String) async throws {
        guard AXIsProcessTrusted() else {
            throw TextInsertionError.accessibilityPermissionMissing
        }

        guard let target = captureTargetContext() else {
            throw TextInsertionError.noActiveTarget
        }

        let snapshot = clipboardService.snapshot()
        guard clipboardService.setString(text) else {
            throw TextInsertionError.clipboardWriteFailed
        }

        defer {
            let restored = clipboardService.restore(snapshot)
            if !restored {
                AppLogger.error(AppLogger.app, "Clipboard restore failed after insertion attempt")
            }
        }

        try postPasteShortcut(to: target.processID)
        try await Task.sleep(nanoseconds: verificationDelayNanoseconds)

        guard isPasteLikelySuccessful(expected: target) else {
            throw TextInsertionError.pasteLikelyFailed
        }
    }

    private func captureTargetContext() -> TargetContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return TargetContext(processID: app.processIdentifier)
    }

    private func postPasteShortcut(to processID: pid_t) throws {
        guard
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        else {
            throw TextInsertionError.failedToCreatePasteEvents
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.postToPid(processID)
        keyUp.postToPid(processID)
    }

    private func isPasteLikelySuccessful(expected target: TargetContext) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        return frontmost.processIdentifier == target.processID
    }
}
