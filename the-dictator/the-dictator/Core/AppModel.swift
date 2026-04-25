import AppKit
import Combine
import Foundation

struct AudioInputOption: Identifiable, Equatable {
    let id: String
    let title: String
    let uid: String?
    let isUnavailable: Bool
}

@MainActor
final class AppModel: ObservableObject {
    // Naming convention:
    // - `workflow*` fields are mirrored from DictationWorkflow snapshot/output.
    // - `modelManager*` fields belong to model catalog/install/download UI state.
    // This keeps ownership explicit at the seam and avoids mixed authorities.
    @Published private(set) var workflowSnapshotState: AppWorkflowState = .idle {
        didSet {
            AppLogger.info(AppLogger.workflow, "Workflow state changed: \(String(describing: workflowSnapshotState))")
            indicatorService.update(for: workflowSnapshotState)
        }
    }
    @Published private(set) var microphonePermissionStatus: String = "Unknown"
    @Published private(set) var accessibilityPermissionStatus: String = "Unknown"
    @Published private(set) var backendCapabilitiesDescription: String = "Unknown"
    @Published private(set) var workflowRuntimePreflightDescription: String = "Checking bundled runtime assets…"
    @Published private(set) var workflowRuntimeIssue: String?
    @Published private(set) var audioInputOptions: [AudioInputOption] = []
    @Published private(set) var selectedAudioInputOptionID: String = "systemDefault"
    @Published private(set) var audioInputStatusDescription: String = "Following System Default input."
    @Published private(set) var modelManagerAvailableModels: [ManagedModelDescriptor] = []
    @Published private(set) var installedModelIDs: Set<String> = []
    @Published private(set) var modelManagerDownloadStates: [String: ModelDownloadState] = [:]
    @Published private(set) var updateAvailableModelIDs: Set<String> = []
    @Published private(set) var modelManagerStatusMessage: String?
    @Published private(set) var modelManagerCatalogLastRefreshedAt: Date?
    @Published private(set) var modelManagerCatalogNextRetryAt: Date?
    @Published private(set) var modelManagerIsRefreshingCatalog: Bool = false

    private var isUsingFallbackModelCatalog: Bool = false
    private var modelCatalogConsecutiveFailures: Int = 0
    private var activeModelCatalogRefreshTask: Task<Void, Never>?

    let settingsStore: SettingsStore
    let sessionStore: SessionStore

    private let notificationService: NotificationService
    private let indicatorService: IndicatorService
    private let hotkeyService: HotkeyService?
    private let audioInputDeviceService: AudioInputDeviceService
    private let transcriptionService: TranscriptionService
    private let permissionsService: PermissionsService
    private let escapeMonitorService: EscapeMonitorService
    private let modelStoreService: ModelStoreService
    private let modelCatalogService: ModelCatalogService
    private let modelDownloadService: ModelDownloadService
    private let modelIntegrityService: ModelIntegrityService
    private let dictationWorkflow: DictationWorkflow

    private var cancellables = Set<AnyCancellable>()
    private var installedModelRecordsByID: [String: InstalledModelRecord] = [:]
    private var visibleSettingsWindowCount: Int = 0

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
        settingsStore: SettingsStore,
        sessionStore: SessionStore,
        notificationService: NotificationService,
        indicatorService: IndicatorService,
        hotkeyService: HotkeyService?,
        audioCaptureService: AudioCaptureService,
        audioInputDeviceService: AudioInputDeviceService,
        audioCueService: AudioCueService,
        transcriptionService: TranscriptionService,
        textInsertionService: TextInsertionService,
        permissionsService: PermissionsService,
        escapeMonitorService: EscapeMonitorService,
        latencyTracker: LatencyTracker,
        modelStoreService: ModelStoreService,
        modelCatalogService: ModelCatalogService,
        modelDownloadService: ModelDownloadService,
        modelIntegrityService: ModelIntegrityService
    ) {
        self.settingsStore = settingsStore
        self.sessionStore = sessionStore
        self.notificationService = notificationService
        self.indicatorService = indicatorService
        self.hotkeyService = hotkeyService
        self.audioInputDeviceService = audioInputDeviceService
        self.transcriptionService = transcriptionService
        self.permissionsService = permissionsService
        self.escapeMonitorService = escapeMonitorService
        self.modelStoreService = modelStoreService
        self.modelCatalogService = modelCatalogService
        self.modelDownloadService = modelDownloadService
        self.modelIntegrityService = modelIntegrityService
        self.dictationWorkflow = DictationWorkflow(
            settingsStore: settingsStore,
            sessionStore: sessionStore,
            audioCaptureService: audioCaptureService,
            audioInputDeviceService: audioInputDeviceService,
            audioCueService: audioCueService,
            transcriptionService: transcriptionService,
            textInsertionService: textInsertionService,
            permissionsService: permissionsService,
            latencyTracker: latencyTracker,
            modelStoreService: modelStoreService,
            notificationService: notificationService
        )

        self.modelDownloadService.onStateChange = { [weak self] modelID, state in
            Task { @MainActor in
                self?.modelManagerDownloadStates[modelID] = state
            }
        }

        notificationService.requestAuthorizationIfNeeded()
        permissionsService.runFirstLaunchChecksIfNeeded(notificationService: notificationService)
        bindDictationWorkflow()
        setupHotkeyCallbacks()
        bindSettings()
        registerPushToTalkHotkey()
        setupEscapeMonitoring()
        refreshPermissionStatuses()
        refreshBackendCapabilitiesDescription()
        refreshAudioInputState()
        registerBundledBaseModelIfAvailable()
        refreshInstalledModels()
        refreshModelCatalog()
        dictationWorkflow.refreshRuntimeReadiness(notifyIfNeeded: false)
    }

    convenience init() {
        let settingsStore = SettingsStore()
        let sessionStore = SessionStore()
        let notificationService = NotificationService()
        let indicatorService = IndicatorService()
        let audioCaptureService = AudioCaptureService()
        let audioInputDeviceService = AudioInputDeviceService()
        let audioCueService = AudioCueService()
        let hotkeyService = try? HotkeyService()
        let transcriptionService = TranscriptionService()
        let textInsertionService = TextInsertionService()
        let permissionsService = PermissionsService()
        let escapeMonitorService = EscapeMonitorService()
        let latencyTracker = LatencyTracker()
        let modelStoreService = ModelStoreService()
        let modelCatalogService = ModelCatalogService(manifestURL: AppConfiguration.modelManifestURL)
        let modelDownloadService = ModelDownloadService()
        let modelIntegrityService = ModelIntegrityService()

        self.init(
            settingsStore: settingsStore,
            sessionStore: sessionStore,
            notificationService: notificationService,
            indicatorService: indicatorService,
            hotkeyService: hotkeyService,
            audioCaptureService: audioCaptureService,
            audioInputDeviceService: audioInputDeviceService,
            audioCueService: audioCueService,
            transcriptionService: transcriptionService,
            textInsertionService: textInsertionService,
            permissionsService: permissionsService,
            escapeMonitorService: escapeMonitorService,
            latencyTracker: latencyTracker,
            modelStoreService: modelStoreService,
            modelCatalogService: modelCatalogService,
            modelDownloadService: modelDownloadService,
            modelIntegrityService: modelIntegrityService
        )

        if hotkeyService == nil {
            notificationService.show(title: "The Dictator", body: "Hotkey service failed to initialize.")
        }
    }

    var menuBarSymbolName: String {
        switch workflowSnapshotState {
        case .idle:
            return "mic"
        case .recording:
            return "waveform"
        case .transcribing:
            return "hourglass"
        case .inserting:
            return "square.and.arrow.down"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    func prepareForSettingsPresentation() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func settingsWindowDidAppear() {
        visibleSettingsWindowCount += 1
        NSApp.setActivationPolicy(.regular)
    }

    func settingsWindowDidDisappear() {
        visibleSettingsWindowCount = max(0, visibleSettingsWindowCount - 1)

        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicyForVisibleWindows()
        }
    }

    private func updateActivationPolicyForVisibleWindows() {
        guard visibleSettingsWindowCount == 0 else {
            return
        }

        if hasVisibleAppWindows() {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func hasVisibleAppWindows() -> Bool {
        NSApp.windows.contains { window in
            guard window.isVisible, !window.isMiniaturized else {
                return false
            }

            let className = NSStringFromClass(type(of: window))
            if className.contains("NSStatusBarWindow") || className.contains("NSMenuWindow") {
                return false
            }

            return window.styleMask.contains(.titled) || window.canBecomeMain || window.canBecomeKey
        }
    }

    private func bindDictationWorkflow() {
        dictationWorkflow.$snapshot
            .sink { [weak self] snapshot in
                guard let self else { return }
                workflowSnapshotState = snapshot.state
                workflowRuntimeIssue = snapshot.runtimeIssue
                workflowRuntimePreflightDescription = snapshot.modelRuntimePreflightDescription
            }
            .store(in: &cancellables)

        dictationWorkflow.onOutcome = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .notification(let body):
                notificationService.show(title: "The Dictator", body: body)
            case .permissionStatusMayHaveChanged:
                refreshPermissionStatuses()
            }
        }
    }

    func requestMicrophonePermission() {
        Task { @MainActor in
            let granted = await permissionsService.requestMicrophonePermissionForRecording(notificationService: notificationService)
            refreshPermissionStatuses()
            notificationService.show(
                title: "The Dictator",
                body: granted ? "Microphone permission granted." : "Microphone permission not granted."
            )
        }
    }

    func openMicrophonePrivacySettings() {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            notificationService.show(title: "The Dictator", body: "Unable to open Microphone privacy settings.")
            return
        }

        let opened = NSWorkspace.shared.open(settingsURL)
        if !opened {
            notificationService.show(title: "The Dictator", body: "Unable to open Microphone privacy settings.")
        }
    }

    func refreshPermissionStatuses() {
        microphonePermissionStatus = permissionsService.microphonePermissionStatusDescription()
        accessibilityPermissionStatus = permissionsService.isAccessibilityPermissionGranted() ? "Allowed" : "Not allowed"
    }

    func refreshAudioInputDevices() {
        audioInputDeviceService.refreshDevices()
        refreshAudioInputState()
    }

    func selectAudioInputOption(id: String) {
        if id == "systemDefault" {
            settingsStore.update { settings in
                settings.audioInputPreference = .systemDefault
            }
            refreshAudioInputState()
            return
        }

        guard id.hasPrefix("device:") else { return }
        let uid = String(id.dropFirst("device:".count))
        let deviceName = audioInputDeviceService.inputDevice(forUID: uid)?.name ?? settingsStore.settings.preferredAudioInputName

        settingsStore.update { settings in
            settings.audioInputPreference = .specificDevice(uid: uid)
            settings.preferredAudioInputName = deviceName
        }

        refreshAudioInputState()
    }

    func pasteLastTranscript() {
        dictationWorkflow.pasteLastTranscript()
    }

    func refreshModelCatalog(force: Bool = false) {
        if activeModelCatalogRefreshTask != nil {
            return
        }

        if !force, let nextRetryAt = modelManagerCatalogNextRetryAt, Date() < nextRetryAt {
            let remaining = max(Int(nextRetryAt.timeIntervalSinceNow.rounded()), 1)
            modelManagerStatusMessage = "Model catalog retry scheduled in \(remaining)s."
            return
        }

        modelManagerIsRefreshingCatalog = true
        activeModelCatalogRefreshTask = Task { @MainActor in
            defer {
                activeModelCatalogRefreshTask = nil
                modelManagerIsRefreshingCatalog = false
            }

            do {
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                let manifest = try await modelCatalogService.fetchManifest()
                let compatible = modelCatalogService.compatibleModels(from: manifest, appVersion: appVersion)
                modelManagerAvailableModels = compatible.sorted { $0.diskBytes < $1.diskBytes }
                isUsingFallbackModelCatalog = false
                modelCatalogConsecutiveFailures = 0
                modelManagerCatalogNextRetryAt = nil
                modelManagerCatalogLastRefreshedAt = Date()
                modelManagerStatusMessage = compatible.isEmpty ? "No compatible models available for this app version." : nil
            } catch {
                modelManagerAvailableModels = Self.fallbackModelCatalog
                isUsingFallbackModelCatalog = true
                modelCatalogConsecutiveFailures += 1
                let retryDelay = Self.catalogRetryDelaySeconds(failureCount: modelCatalogConsecutiveFailures)
                modelManagerCatalogNextRetryAt = Date().addingTimeInterval(retryDelay)
                modelManagerStatusMessage = "Unable to load online model catalog. Showing local fallback metadata."
            }

            refreshInstalledModels()
        }
    }

    func refreshInstalledModels() {
        let installedRecords = modelStoreService.allInstalled()
        installedModelIDs = Set(installedRecords.map(\.modelID))
        installedModelRecordsByID = Dictionary(uniqueKeysWithValues: installedRecords.map { ($0.modelID, $0) })

        let updates = modelManagerAvailableModels.compactMap { descriptor -> String? in
            guard let installed = installedModelRecordsByID[descriptor.id] else {
                return nil
            }
            if isUsingFallbackModelCatalog {
                return nil
            }
            return installed.version != descriptor.version ? descriptor.id : nil
        }
        updateAvailableModelIDs = Set(updates)
        dictationWorkflow.refreshRuntimeReadiness()
    }

    func isModelInstalled(_ modelID: String) -> Bool {
        installedModelIDs.contains(modelID)
    }

    func isModelUpdateAvailable(_ modelID: String) -> Bool {
        updateAvailableModelIDs.contains(modelID)
    }

    func selectModel(id: String) {
        settingsStore.update { settings in
            settings.selectedModelID = id
            settings.useCustomModelPath = false
        }
    }

    func performRuntimeRecoveryAction() {
        let previousModelID = settingsStore.settings.selectedModelID
        guard let recoveryModelID = runtimeRecoveryTargetModelID else {
            return
        }

        AppLogger.info(
            AppLogger.settings,
            "Runtime recovery action: switching model from \(previousModelID) to \(recoveryModelID)."
        )

        selectModel(id: recoveryModelID)
        if recoveryModelID == "base" {
            modelManagerStatusMessage = "Switched to bundled base model."
        } else {
            modelManagerStatusMessage = "Switched to installed model: \(recoveryModelID)."
        }
        dictationWorkflow.refreshRuntimeReadiness(notifyIfNeeded: false)
    }

    func downloadModel(id: String) {
        guard let descriptor = modelManagerAvailableModels.first(where: { $0.id == id }) else {
            modelManagerStatusMessage = "Unknown model selection: \(id)."
            return
        }

        Task { @MainActor in
            modelManagerDownloadStates[id] = .downloading(progress: 0)

            do {
                let tempURL = try await modelDownloadService.startDownload(descriptor)
                let expectedHash = descriptor.sha256.trimmingCharacters(in: .whitespacesAndNewlines)
                if !expectedHash.isEmpty {
                    try modelIntegrityService.verifySHA256(fileURL: tempURL, expectedHex: expectedHash)
                }
                _ = try modelStoreService.install(tempFileURL: tempURL, descriptor: descriptor)
                refreshInstalledModels()
                modelManagerDownloadStates[id] = .completed(tempFilePath: tempURL.path)
                modelManagerStatusMessage = "Installed \(descriptor.displayName) (\(descriptor.technicalName))."
            } catch {
                if let downloadError = error as? ModelDownloadError, case .cancelled = downloadError {
                    modelManagerDownloadStates[id] = .idle
                    modelManagerStatusMessage = "Download cancelled for \(descriptor.displayName)."
                    return
                }

                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let visibleMessage = message.isEmpty ? "Unknown error" : message
                modelManagerDownloadStates[id] = .failed(message: visibleMessage)
                modelManagerStatusMessage = "Failed to install \(descriptor.displayName): \(visibleMessage)"
                AppLogger.error(AppLogger.settings, "Model install failed for \(descriptor.id): \(visibleMessage)")
            }
        }
    }

    func cancelModelDownload(id: String) {
        modelDownloadService.cancelDownload(modelID: id)
        modelManagerDownloadStates[id] = .idle
    }

    func deleteModel(id: String) {
        guard canDeleteModel(id) else {
            modelManagerStatusMessage = "\(id) is bundled with the app and cannot be deleted."
            return
        }

        do {
            try modelStoreService.delete(modelID: id)
            refreshInstalledModels()
            modelManagerDownloadStates[id] = .idle
            modelManagerStatusMessage = "Deleted model \(id)."
        } catch {
            modelManagerStatusMessage = "Failed to delete model \(id): \(error.localizedDescription)"
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
        if let installed = installedModelRecordsByID[descriptor.id]?.version {
            return installed == available ? "Version: \(available)" : "Installed: \(installed) • Available: \(available)"
        }
        return "Available version: \(available)"
    }

    func isBundledModel(_ modelID: String) -> Bool {
        modelManagerAvailableModels.first(where: { $0.id == modelID })?.bundled ?? false
    }

    func canDeleteModel(_ modelID: String) -> Bool {
        isModelInstalled(modelID) && !isBundledModel(modelID)
    }

    var isUsingFallbackCatalog: Bool {
        isUsingFallbackModelCatalog
    }

    var modelManagerCatalogRefreshDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short

        let refreshedText: String
        if let refreshedAt = modelManagerCatalogLastRefreshedAt {
            refreshedText = "Last refresh \(formatter.localizedString(for: refreshedAt, relativeTo: Date()))"
        } else {
            refreshedText = "Catalog not refreshed yet"
        }

        if let retryAt = modelManagerCatalogNextRetryAt, Date() < retryAt {
            return "\(refreshedText) • Retry \(formatter.localizedString(for: retryAt, relativeTo: Date()))"
        }

        return refreshedText
    }

    var modelManagerOnboardingHint: String? {
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

    private var runtimeRecoveryTargetModelID: String? {
        let settings = settingsStore.settings
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

        if let preferredInstalled = modelManagerAvailableModels
            .map(\.id)
            .first(where: { $0 != selected && isModelInstalled($0) }) {
            return preferredInstalled
        }

        return installedModelIDs
            .sorted()
            .first(where: { $0 != selected })
    }

    func modelStatus(for modelID: String) -> String {
        if case .downloading(let progress) = modelManagerDownloadStates[modelID] {
            return "Downloading \(Int(progress * 100))%"
        }

        if case .failed = modelManagerDownloadStates[modelID] {
            return "Failed"
        }

        if settingsStore.settings.selectedModelID == modelID && !settingsStore.settings.useCustomModelPath {
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

    private func setupEscapeMonitoring() {
        escapeMonitorService.onEscape = { [weak self] in
            self?.dictationWorkflow.cancelIfActive()
        }
        escapeMonitorService.start()
    }

    private func setupHotkeyCallbacks() {
        hotkeyService?.onKeyDown = { [weak self] in
            Task { @MainActor in
                await self?.dictationWorkflow.startDictation()
            }
        }

        hotkeyService?.onKeyUp = { [weak self] in
            Task { @MainActor in
                self?.dictationWorkflow.finishDictationHold()
            }
        }
    }

    private func bindSettings() {
        settingsStore.$settings
            .map(\.pushToTalkHotkey)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.registerPushToTalkHotkey()
            }
            .store(in: &cancellables)

        settingsStore.$settings
            .map(\.backendType)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshBackendCapabilitiesDescription()
            }
            .store(in: &cancellables)

        settingsStore.$settings
            .map { "\($0.useCustomModelPath)|\($0.customModelPath)|\($0.selectedModelID)" }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.dictationWorkflow.refreshRuntimeReadiness()
            }
            .store(in: &cancellables)

        settingsStore.$settings
            .map { settings in
                switch settings.audioInputPreference {
                case .systemDefault:
                    return "systemDefault|\(settings.preferredAudioInputName)"
                case .specificDevice(let uid):
                    return "device:\(uid)|\(settings.preferredAudioInputName)"
                }
            }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshAudioInputState()
            }
            .store(in: &cancellables)

        audioInputDeviceService.$devices
            .sink { [weak self] _ in
                self?.refreshAudioInputState()
            }
            .store(in: &cancellables)
    }

    private func registerPushToTalkHotkey() {
        guard let hotkeyService else {
            return
        }

        let configuredHotkey = settingsStore.settings.pushToTalkHotkey
        let displayHotkey = HotkeyParser.displayName(forStoredValue: configuredHotkey)

        do {
            try hotkeyService.register(from: configuredHotkey)
            AppLogger.info(AppLogger.app, "Push-to-talk hotkey active: \(displayHotkey)")
        } catch {
            hotkeyService.unregister()
            AppLogger.error(AppLogger.app, "Hotkey registration failed for '\(displayHotkey)': \(error.localizedDescription)")
            notificationService.show(
                title: "The Dictator",
                body: "Failed to register push-to-talk hotkey: \(displayHotkey). Choose a different shortcut in Settings."
            )
        }
    }

    private func refreshBackendCapabilitiesDescription() {
        do {
            let capabilities = try transcriptionService.capabilities(for: settingsStore.settings.backendType)
            let autoDetect = capabilities.supportsLanguageAutoDetect ? "yes" : "no"
            let explicitLanguage = capabilities.supportsExplicitLanguageSelection ? "yes" : "no"
            let cancellation = capabilities.supportsCancellation ? "yes" : "no"
            let timeout = Int(capabilities.defaultTimeoutSeconds)
            let notes = capabilities.notes.map { " | \($0)" } ?? ""

            backendCapabilitiesDescription = "Auto-detect: \(autoDetect), language select: \(explicitLanguage), cancel: \(cancellation), timeout: \(timeout)s\(notes)"
        } catch {
            backendCapabilitiesDescription = "Unavailable for backend: \(settingsStore.settings.backendType)"
        }
    }

    private func refreshAudioInputState() {
        let devices = audioInputDeviceService.devices
        let preference = settingsStore.settings.audioInputPreference
        let preferredName = settingsStore.settings.preferredAudioInputName

        var options: [AudioInputOption] = []

        if let defaultDevice = devices.first(where: { $0.isSystemDefault }) {
            options.append(
                AudioInputOption(
                    id: "systemDefault",
                    title: "System Default (\(defaultDevice.name))",
                    uid: defaultDevice.uid,
                    isUnavailable: false
                )
            )
        } else {
            options.append(AudioInputOption(id: "systemDefault", title: "System Default", uid: nil, isUnavailable: false))
        }

        let nonDefaultDevices = devices.filter { !$0.isSystemDefault }
        options.append(
            contentsOf: nonDefaultDevices.map {
                AudioInputOption(id: "device:\($0.uid)", title: $0.name, uid: $0.uid, isUnavailable: !$0.isAvailable)
            }
        )

        if case .specificDevice(let uid) = preference,
           !options.contains(where: { $0.id == "device:\(uid)" }) {
            let unavailableName = preferredName.isEmpty ? uid : preferredName
            options.append(
                AudioInputOption(
                    id: "device:\(uid)",
                    title: "\(unavailableName) (Unavailable)",
                    uid: uid,
                    isUnavailable: true
                )
            )
        }

        audioInputOptions = options

        switch preference {
        case .systemDefault:
            selectedAudioInputOptionID = "systemDefault"
            audioInputStatusDescription = "Following System Default input."
        case .specificDevice(let uid):
            selectedAudioInputOptionID = "device:\(uid)"
            if let device = devices.first(where: { $0.uid == uid && $0.isAvailable }) {
                audioInputStatusDescription = "Using \(device.name)."
            } else {
                audioInputStatusDescription = "Currently using System Default until this device reconnects."
            }
        }
    }

}
