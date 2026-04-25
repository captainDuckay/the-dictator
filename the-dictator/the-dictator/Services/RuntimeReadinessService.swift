import Foundation

protocol DictationRuntimeReadinessProviding {
    func modelRuntimePreflightDescription() -> String
    func runtimeIssue(for settings: AppSettings) -> String?
}

final class RuntimeReadinessService: DictationRuntimeReadinessProviding {
    private let modelStoreService: ModelStoreService
    private let fileExists: (String) -> Bool
    private let executableExists: (String) -> Bool
    private let pathProvider: () -> String

    init(
        modelStoreService: ModelStoreService,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        executableExists: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        pathProvider: @escaping () -> String = { ProcessInfo.processInfo.environment["PATH"] ?? "" }
    ) {
        self.modelStoreService = modelStoreService
        self.fileExists = fileExists
        self.executableExists = executableExists
        self.pathProvider = pathProvider
    }

    func modelRuntimePreflightDescription() -> String {
        let bundledCLI = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("whisper-cli", isDirectory: false)

        let cliStatus: String
        if let bundledCLI, FileManager.default.isExecutableFile(atPath: bundledCLI.path) {
            cliStatus = "Bundled whisper-cli: ready"
        } else {
            cliStatus = "Bundled whisper-cli: missing"
        }

        let modelStatus = bundledBaseModelURL() == nil ? "Bundled base model: missing" : "Bundled base model: ready"
        return "\(cliStatus) • \(modelStatus)"
    }

    func runtimeIssue(for settings: AppSettings) -> String? {
        if !hasUsableWhisperExecutable() {
            return "Transcription engine is unavailable. Reinstall the app or add whisper-cli to PATH."
        }

        if settings.useCustomModelPath {
            if settings.customModelPath.isEmpty || !fileExists(settings.customModelPath) {
                return "Custom model file is unavailable. Choose a valid model file in Settings → Transcription."
            }
            return nil
        }

        if modelStoreService.localPath(for: settings.selectedModelID) == nil {
            return "Selected model \(settings.selectedModelID) is not installed. Open Settings → Transcription and download it in Model Manager."
        }

        return nil
    }

    private func bundledBaseModelURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }

        let candidates = [
            resourceURL.appendingPathComponent("models/base/model.bin", isDirectory: false),
            resourceURL.appendingPathComponent("models/base.bin", isDirectory: false),
            resourceURL.appendingPathComponent("base.bin", isDirectory: false),
        ]

        return candidates.first(where: { fileExists($0.path) })
    }

    private func hasUsableWhisperExecutable() -> Bool {
        if let bundledExecutable = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("whisper-cli", isDirectory: false),
           executableExists(bundledExecutable.path) {
            return true
        }

        let knownPaths = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/usr/bin/whisper-cli",
        ]

        if knownPaths.contains(where: { executableExists($0) }) {
            return true
        }

        let environmentPath = pathProvider()
        for pathEntry in environmentPath.split(separator: ":") {
            let candidate = String(pathEntry) + "/whisper-cli"
            if executableExists(candidate) {
                return true
            }
        }

        return false
    }
}
