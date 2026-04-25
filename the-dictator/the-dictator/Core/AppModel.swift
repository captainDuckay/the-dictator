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
    // - `modelManager*` fields are mirrored from ModelManagerModule snapshot/output.
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

    let settingsStore: SettingsStore
    let sessionStore: SessionStore

    private let notificationService: NotificationService
    private let indicatorService: IndicatorService
    private let hotkeyService: HotkeyService?
    private let audioInputDeviceService: AudioInputDeviceService
    private let transcriptionService: TranscriptionService
    private let permissionsService: PermissionsService
    private let escapeMonitorService: EscapeMonitorService
    private let dictationWorkflow: DictationWorkflow
    private let modelManager: ModelManagerModule

    private var cancellables = Set<AnyCancellable>()
    private var visibleSettingsWindowCount: Int = 0

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
        modelIntegrityService: ModelIntegrityService,
        runtimeReadinessService: DictationRuntimeReadinessProviding
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

        self.modelManager = ModelManagerModule(
            settingsProvider: settingsStore,
            modelStoreService: modelStoreService,
            modelCatalogService: modelCatalogService,
            modelDownloadService: modelDownloadService,
            modelIntegrityService: modelIntegrityService
        )

        self.dictationWorkflow = DictationWorkflow(
            settingsProvider: settingsStore,
            sessionStore: sessionStore,
            audioCaptureService: audioCaptureService,
            audioInputDeviceService: audioInputDeviceService,
            audioCueService: audioCueService,
            transcriptionService: transcriptionService,
            textInsertionService: textInsertionService,
            permissionsService: permissionsService,
            latencyTracker: latencyTracker,
            runtimeReadinessProvider: runtimeReadinessService,
            notificationService: notificationService
        )

        self.modelManager.onInventoryChanged = { [weak self] in
            self?.dictationWorkflow.refreshRuntimeReadiness()
        }

        notificationService.requestAuthorizationIfNeeded()
        permissionsService.runFirstLaunchChecksIfNeeded(notificationService: notificationService)
        bindDictationWorkflow()
        bindModelManager()
        setupHotkeyCallbacks()
        bindSettings()
        registerPushToTalkHotkey()
        setupEscapeMonitoring()
        refreshPermissionStatuses()
        refreshBackendCapabilitiesDescription()
        refreshAudioInputState()
        applyModelManagerSnapshot(modelManager.snapshot)
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
        let runtimeReadinessService = RuntimeReadinessService(modelStoreService: modelStoreService)

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
            modelIntegrityService: modelIntegrityService,
            runtimeReadinessService: runtimeReadinessService
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

    private func bindModelManager() {
        modelManager.$snapshot
            .sink { [weak self] snapshot in
                self?.applyModelManagerSnapshot(snapshot)
            }
            .store(in: &cancellables)
    }

    private func applyModelManagerSnapshot(_ snapshot: ModelManagerSnapshot) {
        modelManagerAvailableModels = snapshot.availableModels
        installedModelIDs = snapshot.installedModelIDs
        modelManagerDownloadStates = snapshot.downloadStates
        updateAvailableModelIDs = snapshot.updateAvailableModelIDs
        modelManagerStatusMessage = snapshot.statusMessage
        modelManagerCatalogLastRefreshedAt = snapshot.catalogLastRefreshedAt
        modelManagerCatalogNextRetryAt = snapshot.catalogNextRetryAt
        modelManagerIsRefreshingCatalog = snapshot.isRefreshingCatalog
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
        modelManager.refreshModelCatalog(force: force)
    }

    func refreshInstalledModels() {
        modelManager.refreshInstalledModels()
    }

    func isModelInstalled(_ modelID: String) -> Bool {
        modelManager.isModelInstalled(modelID)
    }

    func isModelUpdateAvailable(_ modelID: String) -> Bool {
        modelManager.isModelUpdateAvailable(modelID)
    }

    func selectModel(id: String) {
        modelManager.selectModel(id: id)
    }

    func performRuntimeRecoveryAction() {
        modelManager.performRuntimeRecoveryAction()
        dictationWorkflow.refreshRuntimeReadiness(notifyIfNeeded: false)
    }

    func downloadModel(id: String) {
        modelManager.downloadModel(id: id)
    }

    func cancelModelDownload(id: String) {
        modelManager.cancelModelDownload(id: id)
    }

    func deleteModel(id: String) {
        modelManager.deleteModel(id: id)
    }

    func modelLabel(for descriptor: ManagedModelDescriptor) -> String {
        modelManager.modelLabel(for: descriptor)
    }

    func modelResourceHint(for descriptor: ManagedModelDescriptor) -> String {
        modelManager.modelResourceHint(for: descriptor)
    }

    func modelVersionHint(for descriptor: ManagedModelDescriptor) -> String {
        modelManager.modelVersionHint(for: descriptor)
    }

    func isBundledModel(_ modelID: String) -> Bool {
        modelManager.isBundledModel(modelID)
    }

    func canDeleteModel(_ modelID: String) -> Bool {
        modelManager.canDeleteModel(modelID)
    }

    var isUsingFallbackCatalog: Bool {
        modelManager.snapshot.isUsingFallbackCatalog
    }

    var modelManagerCatalogRefreshDescription: String {
        modelManager.catalogRefreshDescription()
    }

    var modelManagerOnboardingHint: String? {
        modelManager.onboardingHint
    }

    var runtimeRecoveryActionTitle: String? {
        modelManager.runtimeRecoveryActionTitle
    }

    func modelStatus(for modelID: String) -> String {
        modelManager.modelStatus(for: modelID)
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
