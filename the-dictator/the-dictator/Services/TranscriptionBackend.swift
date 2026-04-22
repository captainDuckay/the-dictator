import Foundation

struct BackendConfig: Equatable {
    let modelPath: String
}

struct TranscriptionOptions: Equatable {
    let languageAutoDetect: Bool
    let preferredLanguage: String
    let polishedOutputEnabled: Bool
    let timeoutSeconds: TimeInterval
}

struct TranscriptResult: Equatable {
    let text: String
    let backend: String
}

enum TranscriptionError: LocalizedError, Equatable {
    case unsupportedBackend(String)
    case modelPathMissing
    case modelPathInvalid(String)
    case backendLoadFailed(String)
    case executableNotFound(String)
    case backendRuntimeFailed(String)
    case timedOut(TimeInterval)
    case emptyTranscript
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedBackend(let backend):
            return "Unsupported backend: \(backend)."
        case .modelPathMissing:
            return "Model path is missing."
        case .modelPathInvalid(let path):
            return "Model path is invalid: \(path)."
        case .backendLoadFailed(let message):
            return "Failed to load backend: \(message)."
        case .executableNotFound(let name):
            return "Could not find backend executable: \(name)."
        case .backendRuntimeFailed(let message):
            return "Transcription runtime failed: \(message)."
        case .timedOut(let seconds):
            return "Transcription timed out after \(Int(seconds))s."
        case .emptyTranscript:
            return "Transcription produced no text."
        case .cancelled:
            return "Transcription cancelled."
        }
    }
}

protocol TranscriptionBackend: AnyObject {
    var backendType: String { get }

    func load(config: BackendConfig) throws
    func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> TranscriptResult
    func cancelTranscription()
}
