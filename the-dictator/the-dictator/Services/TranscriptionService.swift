import Foundation

@MainActor
final class TranscriptionService {
    private let whisperCppBackend: TranscriptionBackend
    private let modelStoreService: ModelStoreService
    private var activeTask: Task<TranscriptResult, Error>?

    init(
        whisperCppBackend: TranscriptionBackend,
        modelStoreService: ModelStoreService
    ) {
        self.whisperCppBackend = whisperCppBackend
        self.modelStoreService = modelStoreService
    }

    convenience init() {
        self.init(
            whisperCppBackend: WhisperCppBackend(),
            modelStoreService: ModelStoreService()
        )
    }

    func transcribe(audioURL: URL, settings: AppSettings) async throws -> TranscriptResult {
        cancelInFlightTranscription()

        let task = Task<TranscriptResult, Error> {
            let backend = try self.backend(for: settings.backendType)
            let capabilities = backend.capabilities()
            let resolvedModel = try self.resolveModelSelection(from: settings)
            try backend.load(
                config: BackendConfig(
                    modelPath: resolvedModel.path,
                    modelID: resolvedModel.modelID,
                    isManagedModel: resolvedModel.isManaged
                )
            )

            let options = TranscriptionOptions(
                languageAutoDetect: settings.languageAutoDetect,
                preferredLanguage: settings.preferredLanguage,
                polishedOutputEnabled: settings.polishedOutputEnabled,
                timeoutSeconds: capabilities.defaultTimeoutSeconds
            )

            let result = try await self.withTimeout(seconds: options.timeoutSeconds) {
                try await backend.transcribe(audioURL: audioURL, options: options)
            }

            let polished = self.polishIfNeeded(result.text, enabled: options.polishedOutputEnabled)
            return TranscriptResult(text: polished, backend: result.backend)
        }

        activeTask = task

        do {
            let result = try await task.value
            activeTask = nil
            return result
        } catch {
            activeTask = nil

            if Task.isCancelled {
                throw TranscriptionError.cancelled
            }

            if let transcriptionError = error as? TranscriptionError {
                throw transcriptionError
            }

            throw TranscriptionError.backendRuntimeFailed(error.localizedDescription)
        }
    }

    func capabilities(for backendType: String) throws -> BackendCapabilities {
        try backend(for: backendType).capabilities()
    }

    func cancelInFlightTranscription() {
        activeTask?.cancel()
        whisperCppBackend.cancelTranscription()
        activeTask = nil
    }

    private func backend(for backendType: String) throws -> TranscriptionBackend {
        let normalized = backendType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "whisper.cpp" || normalized == "whispercpp" {
            return whisperCppBackend
        }

        throw TranscriptionError.unsupportedBackend(backendType)
    }

    private func resolveModelSelection(from settings: AppSettings) throws -> (path: String, modelID: String?, isManaged: Bool) {
        if settings.useCustomModelPath {
            let normalizedCustomPath = settings.customModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedCustomPath.isEmpty else {
                throw TranscriptionError.modelPathMissing
            }
            return (normalizedCustomPath, nil, false)
        }

        let normalizedModelID = settings.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else {
            throw TranscriptionError.modelNotInstalled("base")
        }

        guard let localPath = modelStoreService.localPath(for: normalizedModelID) else {
            throw TranscriptionError.modelNotInstalled(normalizedModelID)
        }

        return (localPath, normalizedModelID, true)
    }

    private func polishIfNeeded(_ text: String, enabled: Bool) -> String {
        guard enabled else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let first = collapsed.first else { return collapsed }
        let sentence = first.uppercased() + collapsed.dropFirst()

        if sentence.last == "." || sentence.last == "!" || sentence.last == "?" {
            return sentence
        }

        return sentence + "."
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                let duration = UInt64(seconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: duration)
                throw TranscriptionError.timedOut(seconds)
            }

            let firstResult = try await group.next()
            group.cancelAll()

            guard let firstResult else {
                throw TranscriptionError.backendRuntimeFailed("No result from transcription task")
            }

            return firstResult
        }
    }
}
