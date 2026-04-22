import Foundation

final class WhisperCppBackend: TranscriptionBackend {
    let backendType = "whisper.cpp"

    private var modelPath: String?
    private let executableName = "whisper-cli"
    private var activeProcess: Process?

    func load(config: BackendConfig) throws {
        let normalizedPath = config.modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            throw TranscriptionError.modelPathMissing
        }

        guard FileManager.default.fileExists(atPath: normalizedPath) else {
            throw TranscriptionError.modelPathInvalid(normalizedPath)
        }

        modelPath = normalizedPath
    }

    func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> TranscriptResult {
        guard let modelPath else {
            throw TranscriptionError.backendLoadFailed("Backend not loaded")
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionError.backendRuntimeFailed("Audio file not found")
        }

        let executableURL = try resolveExecutableURL()
        let process = Process()
        process.executableURL = executableURL

        let threadCount = min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 8)

        var arguments = [
            "-m", modelPath,
            "-f", audioURL.path,
            "-t", "\(threadCount)",
            "-nt",
            "-np",
        ]

        if !options.languageAutoDetect {
            arguments.append(contentsOf: ["-l", options.preferredLanguage])
        }

        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        activeProcess = process

        do {
            try process.run()
        } catch {
            activeProcess = nil
            throw TranscriptionError.backendRuntimeFailed(error.localizedDescription)
        }

        do {
            try await withTaskCancellationHandler {
                try await waitUntilProcessTerminates(process)
            } onCancel: {
                process.terminate()
            }
        } catch is CancellationError {
            process.terminate()
            activeProcess = nil
            throw TranscriptionError.cancelled
        }

        activeProcess = nil

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdoutText = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw TranscriptionError.backendRuntimeFailed(stderrText.isEmpty ? "Exit \(process.terminationStatus)" : stderrText)
        }

        guard !stdoutText.isEmpty else {
            throw TranscriptionError.emptyTranscript
        }

        return TranscriptResult(text: stdoutText, backend: backendType)
    }

    func capabilities() -> BackendCapabilities {
        BackendCapabilities(
            supportsLanguageAutoDetect: true,
            supportsExplicitLanguageSelection: true,
            supportsCancellation: true,
            defaultTimeoutSeconds: 30,
            notes: "Requires whisper-cli in PATH and a valid local model file path."
        )
    }

    func cancelTranscription() {
        activeProcess?.terminate()
    }

    private func resolveExecutableURL() throws -> URL {
        let knownPaths = [
            "/opt/homebrew/bin/\(executableName)",
            "/usr/local/bin/\(executableName)",
            "/usr/bin/\(executableName)",
        ]

        for path in knownPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for pathEntry in environmentPath.split(separator: ":") {
            let candidate = String(pathEntry) + "/\(executableName)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        throw TranscriptionError.executableNotFound(executableName)
    }

    private func waitUntilProcessTerminates(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
    }
}
