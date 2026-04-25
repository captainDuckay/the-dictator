import Combine
import Foundation

struct ModelManagerSnapshot: Equatable {
    var availableModels: [ManagedModelDescriptor] = []
    var installedModelIDs: Set<String> = []
    var downloadStates: [String: ModelDownloadState] = [:]
    var updateAvailableModelIDs: Set<String> = []
    var statusMessage: String?
    var catalogLastRefreshedAt: Date?
    var catalogNextRetryAt: Date?
    var isRefreshingCatalog: Bool = false
    var isUsingFallbackCatalog: Bool = false
    var installedRecordsByID: [String: InstalledModelRecord] = [:]
}

@MainActor
final class ModelManagerModule: ObservableObject {
    @Published private(set) var snapshot = ModelManagerSnapshot()

    var onInventoryChanged: (() -> Void)?

    private let settingsProvider: ModelManagerSettingsProviding
    private let modelStoreService: ModelStoreService
    private let modelCatalogService: ModelCatalogService
    private let modelDownloadService: ModelDownloadService
    private let modelIntegrityService: ModelIntegrityService

    private var modelCatalogConsecutiveFailures: Int = 0
    private var activeModelCatalogRefreshTask: Task<Void, Never>?

    private static let fallbackModelCatalog: [ManagedModelDescriptor] = [
        ManagedModelDescriptor(
            id: "tiny",
            level: .tiny,
            displayName: "Fastest",
            technicalName: "tiny",
            diskBytes: 78_000_000,
            estimatedRamBytes: 350_000_000,
            downloadURL: nil,
            sha256: "",
            version: "fallback",
            bundled: false,
            minAppVersion: "0.0.0",
            maxAppVersion: nil
        ),
        ManagedModelDescriptor(
            id: "base",
            level: .base,
            displayName: "Balanced",
            technicalName: "base",
            diskBytes: 142_000_000,
            estimatedRamBytes: 500_000_000,
            downloadURL: nil,
            sha256: "",
            version: "fallback",
            bundled: true,
            minAppVersion: "0.0.0",
            maxAppVersion: nil
        ),
        ManagedModelDescriptor(
            id: "small",
            level: .small,
            displayName: "Higher Accuracy",
            technicalName: "small",
            diskBytes: 488_000_000,
            estimatedRamBytes: 1_300_000_000,
            downloadURL: nil,
            sha256: "",
            version: "fallback",
            bundled: false,
            minAppVersion: "0.0.0",
            maxAppVersion: nil
        ),
        ManagedModelDescriptor(
            id: "medium",
            level: .medium,
            displayName: "High Accuracy",
            technicalName: "medium",
            diskBytes: 1_530_000_000,
            estimatedRamBytes: 3_500_000_000,
            downloadURL: nil,
            sha256: "",
            version: "fallback",
            bundled: false,
            minAppVersion: "0.0.0",
            maxAppVersion: nil
        ),
        ManagedModelDescriptor(
            id: "large",
            level: .large,
            displayName: "Best Accuracy",
            technicalName: "large",
            diskBytes: 3_100_000_000,
            estimatedRamBytes: 6_500_000_000,
            downloadURL: nil,
            sha256: "",
            version: "fallback",
            bundled: false,
            minAppVersion: "0.0.0",
            maxAppVersion: nil
        ),
    ]

    init(
        settingsProvider: ModelManagerSettingsProviding,
        modelStoreService: ModelStoreService,
        modelCatalogService: ModelCatalogService,
        modelDownloadService: ModelDownloadService,
        modelIntegrityService: ModelIntegrityService
    ) {
        self.settingsProvider = settingsProvider
        self.modelStoreService = modelStoreService
        self.modelCatalogService = modelCatalogService
        self.modelDownloadService = modelDownloadService
        self.modelIntegrityService = modelIntegrityService

        self.modelDownloadService.onStateChange = { [weak self] modelID, state in
            Task { @MainActor in
                self?.snapshot.downloadStates[modelID] = state
            }
        }

        registerBundledBaseModelIfAvailable()
        refreshInstalledModels()
        refreshModelCatalog()
    }

    func refreshModelCatalog(force: Bool = false) {
        if activeModelCatalogRefreshTask != nil {
            return
        }

        if !force, let nextRetryAt = snapshot.catalogNextRetryAt, Date() < nextRetryAt {
            let remaining = max(Int(nextRetryAt.timeIntervalSinceNow.rounded()), 1)
            snapshot.statusMessage = "Model catalog retry scheduled in \(remaining)s."
            return
        }

        snapshot.isRefreshingCatalog = true
        activeModelCatalogRefreshTask = Task { @MainActor in
            defer {
                activeModelCatalogRefreshTask = nil
                snapshot.isRefreshingCatalog = false
            }

            do {
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                let manifest = try await modelCatalogService.fetchManifest()
                let compatible = modelCatalogService.compatibleModels(from: manifest, appVersion: appVersion)
                snapshot.availableModels = compatible.sorted { $0.diskBytes < $1.diskBytes }
                snapshot.isUsingFallbackCatalog = false
                modelCatalogConsecutiveFailures = 0
                snapshot.catalogNextRetryAt = nil
                snapshot.catalogLastRefreshedAt = Date()
                snapshot.statusMessage = compatible.isEmpty ? "No compatible models available for this app version." : nil
            } catch {
                snapshot.availableModels = Self.fallbackModelCatalog
                snapshot.isUsingFallbackCatalog = true
                modelCatalogConsecutiveFailures += 1
                let retryDelay = Self.catalogRetryDelaySeconds(failureCount: modelCatalogConsecutiveFailures)
                snapshot.catalogNextRetryAt = Date().addingTimeInterval(retryDelay)
                snapshot.statusMessage = "Unable to load online model catalog. Showing local fallback metadata."
            }

            refreshInstalledModels()
        }
    }

    func refreshInstalledModels() {
        let installedRecords = modelStoreService.allInstalled()
        snapshot.installedModelIDs = Set(installedRecords.map(\.modelID))
        snapshot.installedRecordsByID = Dictionary(uniqueKeysWithValues: installedRecords.map { ($0.modelID, $0) })

        let updates = snapshot.availableModels.compactMap { descriptor -> String? in
            guard let installed = snapshot.installedRecordsByID[descriptor.id] else {
                return nil
            }
            if snapshot.isUsingFallbackCatalog {
                return nil
            }
            return installed.version != descriptor.version ? descriptor.id : nil
        }
        snapshot.updateAvailableModelIDs = Set(updates)
        onInventoryChanged?()
    }

    func isModelInstalled(_ modelID: String) -> Bool {
        snapshot.installedModelIDs.contains(modelID)
    }

    func isModelUpdateAvailable(_ modelID: String) -> Bool {
        snapshot.updateAvailableModelIDs.contains(modelID)
    }

    func selectModel(id: String) {
        settingsProvider.update { settings in
            settings.selectedModelID = id
            settings.useCustomModelPath = false
        }
    }

    func performRuntimeRecoveryAction() {
        let previousModelID = settingsProvider.currentSettings.selectedModelID
        guard let recoveryModelID = runtimeRecoveryTargetModelID else {
            return
        }

        AppLogger.info(
            AppLogger.settings,
            "Runtime recovery action: switching model from \(previousModelID) to \(recoveryModelID)."
        )

        selectModel(id: recoveryModelID)
        if recoveryModelID == "base" {
            snapshot.statusMessage = "Switched to bundled base model."
        } else {
            snapshot.statusMessage = "Switched to installed model: \(recoveryModelID)."
        }
    }

    func downloadModel(id: String) {
        guard let descriptor = snapshot.availableModels.first(where: { $0.id == id }) else {
            snapshot.statusMessage = "Unknown model selection: \(id)."
            return
        }

        Task { @MainActor in
            snapshot.downloadStates[id] = .downloading(progress: 0)

            do {
                let tempURL = try await modelDownloadService.startDownload(descriptor)
                let expectedHash = descriptor.sha256.trimmingCharacters(in: .whitespacesAndNewlines)
                if !expectedHash.isEmpty {
                    try modelIntegrityService.verifySHA256(fileURL: tempURL, expectedHex: expectedHash)
                }
                _ = try modelStoreService.install(tempFileURL: tempURL, descriptor: descriptor)
                refreshInstalledModels()
                snapshot.downloadStates[id] = .completed(tempFilePath: tempURL.path)
                snapshot.statusMessage = "Installed \(descriptor.displayName) (\(descriptor.technicalName))."
            } catch {
                if let downloadError = error as? ModelDownloadError, case .cancelled = downloadError {
                    snapshot.downloadStates[id] = .idle
                    snapshot.statusMessage = "Download cancelled for \(descriptor.displayName)."
                    return
                }

                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let visibleMessage = message.isEmpty ? "Unknown error" : message
                snapshot.downloadStates[id] = .failed(message: visibleMessage)
                snapshot.statusMessage = "Failed to install \(descriptor.displayName): \(visibleMessage)"
                AppLogger.error(AppLogger.settings, "Model install failed for \(descriptor.id): \(visibleMessage)")
            }
        }
    }

    func cancelModelDownload(id: String) {
        modelDownloadService.cancelDownload(modelID: id)
        snapshot.downloadStates[id] = .idle
    }

    func deleteModel(id: String) {
        guard canDeleteModel(id) else {
            snapshot.statusMessage = "\(id) is bundled with the app and cannot be deleted."
            return
        }

        do {
            try modelStoreService.delete(modelID: id)
            refreshInstalledModels()
            snapshot.downloadStates[id] = .idle
            snapshot.statusMessage = "Deleted model \(id)."
        } catch {
            snapshot.statusMessage = "Failed to delete model \(id): \(error.localizedDescription)"
        }
    }

    func modelLabel(for descriptor: ManagedModelDescriptor) -> String {
        "\(descriptor.displayName) (\(descriptor.technicalName))"
    }

    func modelResourceHint(for descriptor: ManagedModelDescriptor) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        let disk = formatter.string(fromByteCount: descriptor.diskBytes)
        let ram = formatter.string(fromByteCount: descriptor.estimatedRamBytes)
        return "Disk: \(disk) • Est. RAM: \(ram)"
    }

    func modelVersionHint(for descriptor: ManagedModelDescriptor) -> String {
        let available = descriptor.version
        if let installed = snapshot.installedRecordsByID[descriptor.id]?.version {
            return installed == available ? "Version: \(available)" : "Installed: \(installed) • Available: \(available)"
        }
        return "Available version: \(available)"
    }

    func isBundledModel(_ modelID: String) -> Bool {
        snapshot.availableModels.first(where: { $0.id == modelID })?.bundled ?? false
    }

    func canDeleteModel(_ modelID: String) -> Bool {
        isModelInstalled(modelID) && !isBundledModel(modelID)
    }

    var onboardingHint: String? {
        if isModelInstalled("base") {
            return "Balanced (base) is bundled and ready for offline dictation."
        }

        return "No bundled base model detected. Download a model to start dictation."
    }

    var runtimeRecoveryActionTitle: String? {
        guard let recoveryModelID = runtimeRecoveryTargetModelID else {
            return nil
        }

        if recoveryModelID == "base" {
            return "Use bundled base model"
        }

        return "Use installed model (\(recoveryModelID))"
    }

    func modelStatus(for modelID: String) -> String {
        if case .downloading(let progress) = snapshot.downloadStates[modelID] {
            return "Downloading \(Int(progress * 100))%"
        }

        if case .failed = snapshot.downloadStates[modelID] {
            return "Failed"
        }

        let settings = settingsProvider.currentSettings
        if settings.selectedModelID == modelID && !settings.useCustomModelPath {
            if isModelInstalled(modelID) {
                return isModelUpdateAvailable(modelID) ? "Active • Update available" : "Active"
            }
            return "Selected (not installed)"
        }

        if isModelInstalled(modelID) {
            if isBundledModel(modelID) {
                return isModelUpdateAvailable(modelID) ? "Bundled • Update available" : "Bundled"
            }
            return isModelUpdateAvailable(modelID) ? "Installed • Update available" : "Installed"
        }

        return "Not installed"
    }

    func catalogRefreshDescription(relativeTo referenceDate: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short

        let refreshedText: String
        if let refreshedAt = snapshot.catalogLastRefreshedAt {
            refreshedText = "Last refresh \(formatter.localizedString(for: refreshedAt, relativeTo: referenceDate))"
        } else {
            refreshedText = "Catalog not refreshed yet"
        }

        if let retryAt = snapshot.catalogNextRetryAt, referenceDate < retryAt {
            return "\(refreshedText) • Retry \(formatter.localizedString(for: retryAt, relativeTo: referenceDate))"
        }

        return refreshedText
    }

    private var runtimeRecoveryTargetModelID: String? {
        let settings = settingsProvider.currentSettings
        guard !settings.useCustomModelPath else {
            return nil
        }

        let selected = settings.selectedModelID
        guard !isModelInstalled(selected) else {
            return nil
        }

        if selected != "base", isModelInstalled("base") {
            return "base"
        }

        if let preferredInstalled = snapshot.availableModels
            .map(\.id)
            .first(where: { $0 != selected && isModelInstalled($0) }) {
            return preferredInstalled
        }

        return snapshot.installedModelIDs
            .sorted()
            .first(where: { $0 != selected })
    }

    private func registerBundledBaseModelIfAvailable() {
        guard let bundledModelURL = bundledBaseModelURL() else {
            return
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        do {
            try modelStoreService.registerBundledModel(modelID: "base", version: appVersion, fileURL: bundledModelURL)
        } catch {
            AppLogger.error(AppLogger.settings, "Failed to register bundled base model: \(error.localizedDescription)")
        }
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

        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private static func catalogRetryDelaySeconds(failureCount: Int) -> TimeInterval {
        let schedule: [TimeInterval] = [5, 15, 30, 60, 120, 300]
        let index = min(max(failureCount - 1, 0), schedule.count - 1)
        return schedule[index]
    }
}
