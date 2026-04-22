import Foundation

enum AppWorkflowState: Equatable {
    case idle
    case recording
    case transcribing
    case inserting
    case error(AppWorkflowError)
}

enum AppWorkflowEvent: Equatable {
    case hotkeyDown(permissionsOK: Bool)
    case hotkeyUp(durationMS: Int)
    case transcriptionSucceeded(text: String)
    case transcriptionFailed(AppWorkflowError)
    case insertionSucceeded
    case insertionFailed(AppWorkflowError)
    case cancel
    case clearError
}

enum AppWorkflowError: LocalizedError, Equatable {
    case permissionsDenied
    case backendUnavailable
    case backendMisconfigured(String)
    case transcriptionFailed
    case insertionFailed
    case noActiveTarget
    case accessibilityDenied
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionsDenied:
            return "Required permissions are missing."
        case .backendUnavailable:
            return "Transcription backend is not configured yet."
        case .backendMisconfigured(let message):
            return message
        case .transcriptionFailed:
            return "Transcription failed."
        case .insertionFailed:
            return "Insertion failed. Use Paste Last Transcript to retry."
        case .noActiveTarget:
            return "No active text target was found. Use Paste Last Transcript after focusing a text field."
        case .accessibilityDenied:
            return "Accessibility permission is required for insertion."
        case .cancelled:
            return "Operation cancelled."
        }
    }
}

struct AppStateMachine {
    static let minimumHoldDurationMS = 250

    static func reduce(state: AppWorkflowState, event: AppWorkflowEvent) -> AppWorkflowState {
        switch (state, event) {
        case (.idle, .hotkeyDown(let permissionsOK)):
            return permissionsOK ? .recording : .idle

        case (.recording, .hotkeyUp(let durationMS)):
            return durationMS < minimumHoldDurationMS ? .idle : .transcribing

        case (.recording, .cancel):
            return .idle

        case (.transcribing, .transcriptionSucceeded):
            return .inserting

        case (.transcribing, .transcriptionFailed):
            return .idle

        case (.transcribing, .cancel):
            return .idle

        case (.inserting, .insertionSucceeded):
            return .idle

        case (.inserting, .insertionFailed):
            return .idle

        case (.inserting, .cancel):
            return .idle

        case (.error, .clearError):
            return .idle

        case (.error, .cancel):
            return .idle

        default:
            return state
        }
    }
}
