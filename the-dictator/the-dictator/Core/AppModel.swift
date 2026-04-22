import AppKit
import Combine
import CoreAudio
import Foundation

struct AudioInputOption: Identifiable, Equatable {
    let id: String
    let title: String
    let uid: String?
    let isUnavailable: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workflowState: AppWorkflowState = .idle {
        didSet {
            AppLogger.info(AppLogger.workflow, "Workflow state changed: \(String(describing: workflowState))")
            indicatorService.update(for: workflowState)
        }
    }
    @Published private(set) var microphonePermissionStatus: String = "Unknown"
    @Published private(set) var accessibilityPermissionStatus: String = "Unknown"
    @Published private(set) var backendCapabilitiesDescription: String = "Unknown"
    @Published private(set) var audioInputOptions: [AudioInputOption] = []
    @Published private(set) var selectedAudioInputOptionID: String = "systemDefault"
    @Published private(set) var audioInputStatusDescription: String = "Following System Default input."
    @Published private(set) var availableModels: [ManagedModelDescriptor] = []
    @Published private(set) var installedModelIDs: Set<String> = []
    @Published private(set) var modelDownloadStates: [String: ModelDownloadState] = [:]
    @Published private(set) var updateAvailableModelIDs: Set<String> = []
    @Published private(set) var modelManagerStatusMessage: String?

    let settingsStore: SettingsStore
    let sessionStore: SessionStore

    private let notificationService: NotificationService
    private let indicatorService: IndicatorService
    private let hotkeyService: HotkeyService?
    private let audioCaptureService: AudioCaptureService
    private let audioInputDeviceService: AudioInputDeviceService
    private let audioCueService: AudioCueService
    private let transcriptionService: TranscriptionService
    private let textInsertionService: TextInsertionService
    private let permissionsService: PermissionsService
    private let escapeMonitorService: EscapeMonitorService
    private let latencyTracker: LatencyTracker
    private let modelStoreService: ModelStoreService
    private let modelCatalogService: ModelCatalogService
    private let modelDownloadService: ModelDownloadService
    private let modelIntegrityService: ModelIntegrityService

    private var cancellables = Set<AnyCancellable>()
    private var recordingStartedAt: Date?
    private var installedModelRecordsByID: [String: InstalledModelRecord] = [:]
    private var activeTranscriptionTask: Task<Void, Never>?
    private var activeInsertionTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var lastInputRoutingState: InputRoutingState?

    private enum InputRoutingState: Equatable {
        case systemDefault
        case preferredAvailable(uid: String)
        case preferredFallback(uid: String)
    }

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
        self.audioCaptureService = audioCaptureService
        self.audioInputDeviceService = audioInputDeviceService
        self.audioCueService = audioCueService
        self.transcriptionService = transcriptionService
        self.textInsertionService = textInsertionService
        self.permissionsService = permissionsService
        self.escapeMonitorService = escapeMonitorService
        self.latencyTracker = latencyTracker
        self.modelStoreService = modelStoreService
        self.modelCatalogService = modelCatalogService
        self.modelDownloadService = modelDownloadService
        self.modelIntegrityService = modelIntegrityService

        self.modelDownloadService.onStateChange = { [weak self] modelID, state in
            Task { @MainActor in
                self?.modelDownloadStates[modelID] = state
            }
        }

        notificationService.requestAuthorizationIfNeeded()
        permissionsService.runFirstLaunchChecksIfNeeded(notificationService: notificationService)
        setupHotkeyCallbacks()
        bindSettings()
        registerPushToTalkHotkey()
        setupEscapeMonitoring()
        refreshPermissionStatuses()
        refreshBackendCapabilitiesDescription()
        refreshAudioInputState()
        refreshInstalledModels()
        refreshModelCatalog()
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
        let manifestURL = URL(string: "https://github.com/captainDuckay/the-dictator-models/releases/latest/download/manifest.json")
            ?? URL(string: "https://example.com/manifest.json")!
        let modelCatalogService = ModelCatalogService(manifestURL: manifestURL)
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
        switch workflowState {
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

    func handle(_ event: AppWorkflowEvent) {
        if case .cancel = event {
            cancelInFlightOperations()
        }

        switch event {
        case .hotkeyDown(let permissionsOK) where !permissionsOK:
            notificationService.show(
                title: "The Dictator",
                body: AppWorkflowError.permissionsDenied.errorDescription ?? "Missing permissions"
            )
        case .transcriptionFailed(let error):
            notificationService.show(title: "The Dictator", body: error.errorDescription ?? "Transcription failed")
        case .insertionFailed(let error):
            notificationService.show(title: "The Dictator", body: error.errorDescription ?? "Insertion failed")
        default:
            break
        }

        let nextState = AppStateMachine.reduce(state: workflowState, event: event)
        workflowState = nextState
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
        guard let transcript = sessionStore.lastRecoverableTranscript, !transcript.isEmpty else {
            notificationService.show(title: "The Dictator", body: "No recoverable transcript available.")
            return
        }

        AppLogger.info(AppLogger.app, "Paste Last Transcript requested for \(transcript.count) chars")
        startInsertion(
            transcript: transcript,
            shouldClearRecoverableTranscriptOnSuccess: false,
            useStateMachineInsertionState: false,
            sessionID: nil
        )
    }

    func refreshModelCatalog() {
        Task { @MainActor in
            do {
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                let manifest = try await modelCatalogService.fetchManifest()
                let compatible = modelCatalogService.compatibleModels(from: manifest, appVersion: appVersion)
                availableModels = compatible.sorted { $0.diskBytes < $1.diskBytes }
                modelManagerStatusMessage = compatible.isEmpty ? "No compatible models available for this app version." : nil
            } catch {
                availableModels = Self.fallbackModelCatalog
                modelManagerStatusMessage = "Unable to load online model catalog. Showing local fallback metadata."
            }

            refreshInstalledModels()
        }
    }

    func refreshInstalledModels() {
        let installedRecords = modelStoreService.allInstalled()
        installedModelIDs = Set(installedRecords.map(\.modelID))
        installedModelRecordsByID = Dictionary(uniqueKeysWithValues: installedRecords.map { ($0.modelID, $0) })

        let updates = availableModels.compactMap { descriptor -> String? in
            guard let installed = installedModelRecordsByID[descriptor.id] else {
                return nil
            }
            return installed.version != descriptor.version ? descriptor.id : nil
        }
        updateAvailableModelIDs = Set(updates)
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

    func downloadModel(id: String) {
        guard let descriptor = availableModels.first(where: { $0.id == id }) else {
            modelManagerStatusMessage = "Unknown model selection: \(id)."
            return
        }

        Task { @MainActor in
            modelDownloadStates[id] = .downloading(progress: 0)

            do {
                let tempURL = try await modelDownloadService.startDownload(descriptor)
                try modelIntegrityService.verifySHA256(fileURL: tempURL, expectedHex: descriptor.sha256)
                _ = try modelStoreService.install(tempFileURL: tempURL, descriptor: descriptor)
                refreshInstalledModels()
                modelDownloadStates[id] = .completed(tempFilePath: tempURL.path)
                modelManagerStatusMessage = "Installed \(descriptor.displayName) (\(descriptor.technicalName))."
            } catch {
                if let downloadError = error as? ModelDownloadError, case .cancelled = downloadError {
                    modelDownloadStates[id] = .idle
                    modelManagerStatusMessage = "Download cancelled for \(descriptor.displayName)."
                    return
                }

                modelDownloadStates[id] = .failed(message: error.localizedDescription)
                modelManagerStatusMessage = "Failed to install \(descriptor.displayName): \(error.localizedDescription)"
            }
        }
    }

    func cancelModelDownload(id: String) {
        modelDownloadService.cancelDownload(modelID: id)
        modelDownloadStates[id] = .idle
    }

    func deleteModel(id: String) {
        do {
            try modelStoreService.delete(modelID: id)
            refreshInstalledModels()
            modelDownloadStates[id] = .idle
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

    func modelStatus(for modelID: String) -> String {
        if case .downloading(let progress) = modelDownloadStates[modelID] {
            return "Downloading \(Int(progress * 100))%"
        }

        if case .failed = modelDownloadStates[modelID] {
            return "Failed"
        }

        if settingsStore.settings.selectedModelID == modelID && !settingsStore.settings.useCustomModelPath {
            if isModelInstalled(modelID) {
                return isModelUpdateAvailable(modelID) ? "Active • Update available" : "Active"
            }
            return "Selected (not installed)"
        }

        if isModelInstalled(modelID) {
            return isModelUpdateAvailable(modelID) ? "Installed • Update available" : "Installed"
        }

        return "Not installed"
    }

    private func setupEscapeMonitoring() {
        escapeMonitorService.onEscape = { [weak self] in
            guard let self else { return }
            if workflowState == .transcribing || workflowState == .inserting {
                handle(.cancel)
            }
        }
        escapeMonitorService.start()
    }

    private func setupHotkeyCallbacks() {
        hotkeyService?.onKeyDown = { [weak self] in
            Task { @MainActor in
                await self?.onPushToTalkDown()
            }
        }

        hotkeyService?.onKeyUp = { [weak self] in
            Task { @MainActor in
                self?.onPushToTalkUp()
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

    private func onPushToTalkDown() async {
        guard workflowState == .idle, activeSessionID == nil else {
            return
        }

        let hasPermission = await permissionsService.requestMicrophonePermissionForRecording(notificationService: notificationService)
        guard hasPermission else {
            handle(.hotkeyDown(permissionsOK: false))
            return
        }

        let captureRoute = resolveCaptureRoute()

        do {
            try audioCaptureService.startCapture(deviceID: captureRoute.deviceID)
            recordingStartedAt = Date()
            activeSessionID = UUID()
            handle(.hotkeyDown(permissionsOK: true))
            updateRouteNotifications(for: captureRoute.routingState)
            audioCueService.playRecordingStarted(enabled: settingsStore.settings.audioCuesEnabled)
        } catch {
            AppLogger.error(AppLogger.app, "Failed to start audio capture: \(error.localizedDescription)")
            notificationService.show(
                title: "The Dictator",
                body: "Couldn’t start recording with current microphone. Try reconnecting or choose another input in Settings."
            )
            audioCaptureService.discardCapture()
            handle(.cancel)
        }
    }

    private func onPushToTalkUp() {
        guard workflowState == .recording, let sessionID = activeSessionID else {
            return
        }

        let durationMS = Int((Date().timeIntervalSince(recordingStartedAt ?? Date())) * 1_000)
        recordingStartedAt = nil
        audioCueService.playRecordingStopped(enabled: settingsStore.settings.audioCuesEnabled)

        if durationMS < AppStateMachine.minimumHoldDurationMS {
            audioCaptureService.discardCapture()
            activeSessionID = nil
            handle(.hotkeyUp(durationMS: durationMS))
            return
        }

        do {
            let outputURL = try audioCaptureService.stopCaptureAndExportWav()
            AppLogger.info(AppLogger.app, "Captured audio clip: \(outputURL.path)")

            latencyTracker.markCaptureEnded(sessionID: sessionID)
            handle(.hotkeyUp(durationMS: durationMS))
            startTranscription(audioURL: outputURL, sessionID: sessionID)
        } catch {
            AppLogger.error(AppLogger.app, "Failed to stop audio capture: \(error.localizedDescription)")
            notificationService.show(title: "The Dictator", body: "Failed to finalize recorded audio.")
            audioCaptureService.discardCapture()
            activeSessionID = nil
            handle(.cancel)
        }
    }

    private func startTranscription(audioURL: URL, sessionID: UUID) {
        guard workflowState == .transcribing, activeSessionID == sessionID else {
            return
        }

        activeTranscriptionTask?.cancel()

        let settings = settingsStore.settings

        activeTranscriptionTask = Task { [weak self] in
            guard let self else { return }

            defer {
                try? FileManager.default.removeItem(at: audioURL)
            }

            do {
                let result = try await transcriptionService.transcribe(audioURL: audioURL, settings: settings)
                guard activeSessionID == sessionID else { return }

                latencyTracker.markTranscriptReady(sessionID: sessionID)
                sessionStore.saveRecoverableTranscript(result.text)
                AppLogger.info(AppLogger.app, "Transcript ready (\(result.backend)): \(result.text)")

                handle(.transcriptionSucceeded(text: result.text))
                startInsertion(
                    transcript: result.text,
                    shouldClearRecoverableTranscriptOnSuccess: true,
                    useStateMachineInsertionState: true,
                    sessionID: sessionID
                )
            } catch {
                let workflowError = mapTranscriptionWorkflowError(error)
                AppLogger.error(AppLogger.app, "Transcription failed: \(workflowError.localizedDescription)")
                latencyTracker.clear(sessionID: sessionID)
                activeSessionID = nil
                handle(.transcriptionFailed(workflowError))
            }
        }
    }

    private func startInsertion(
        transcript: String,
        shouldClearRecoverableTranscriptOnSuccess: Bool,
        useStateMachineInsertionState: Bool,
        sessionID: UUID?
    ) {
        if useStateMachineInsertionState,
           (workflowState != .inserting || activeSessionID == nil || activeSessionID != sessionID) {
            return
        }

        let hasAccessibility = permissionsService.ensureAccessibilityPermission(notificationService: notificationService)
        refreshPermissionStatuses()
        guard hasAccessibility else {
            if useStateMachineInsertionState {
                handle(.insertionFailed(.accessibilityDenied))
            }
            return
        }

        activeInsertionTask?.cancel()
        activeInsertionTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await textInsertionService.insert(text: transcript)

                if useStateMachineInsertionState && activeSessionID != sessionID {
                    return
                }

                if shouldClearRecoverableTranscriptOnSuccess {
                    sessionStore.clearRecoverableTranscript()
                }

                if let sessionID, let latency = latencyTracker.completeInsertion(sessionID: sessionID) {
                    AppLogger.info(
                        AppLogger.app,
                        "Latency session \(latency.sessionID.uuidString): capture->transcript=\(latency.captureToTranscriptMS)ms transcript->insert=\(latency.transcriptToInsertMS)ms total=\(latency.totalCaptureToInsertMS)ms"
                    )
                }

                if useStateMachineInsertionState {
                    handle(.insertionSucceeded)
                    activeSessionID = nil
                }
            } catch {
                let workflowError = mapInsertionWorkflowError(error)
                AppLogger.error(AppLogger.app, "Insertion failed: \(workflowError.localizedDescription)")

                if useStateMachineInsertionState {
                    handle(.insertionFailed(workflowError))
                    if let sessionID {
                        latencyTracker.clear(sessionID: sessionID)
                    }
                    activeSessionID = nil
                } else {
                    notificationService.show(
                        title: "The Dictator",
                        body: workflowError.errorDescription ?? "Paste Last Transcript failed"
                    )
                }
            }
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

    private func resolveCaptureRoute() -> (deviceID: AudioDeviceID?, routingState: InputRoutingState) {
        let settings = settingsStore.settings
        let resolution = audioInputDeviceService.resolve(
            preference: settings.audioInputPreference,
            preferredName: settings.preferredAudioInputName
        )

        switch resolution {
        case .systemDefault(defaultDevice: let defaultDevice):
            let deviceID = defaultDevice.flatMap { audioInputDeviceService.deviceID(forUID: $0.uid) }
            AppLogger.info(AppLogger.app, "Audio input route: system default (\(defaultDevice?.name ?? "unknown"))")
            return (deviceID, .systemDefault)

        case .specificAvailable(device: let device):
            let deviceID = audioInputDeviceService.deviceID(forUID: device.uid)
            AppLogger.info(AppLogger.app, "Audio input route: preferred device \(device.name) uid=\(device.uid)")
            return (deviceID, .preferredAvailable(uid: device.uid))

        case .specificUnavailable(selectedUID: let selectedUID, selectedName: let selectedName, fallbackDevice: let fallbackDevice):
            let fallbackID = fallbackDevice.flatMap { audioInputDeviceService.deviceID(forUID: $0.uid) }
            let preferredDisplay = selectedName.isEmpty ? selectedUID : selectedName
            AppLogger.info(
                AppLogger.app,
                "Audio input route fallback: preferred \(preferredDisplay) uid=\(selectedUID) unavailable, using system default \(fallbackDevice?.name ?? "unknown")"
            )
            return (fallbackID, .preferredFallback(uid: selectedUID))
        }
    }

    private func updateRouteNotifications(for routingState: InputRoutingState) {
        defer { lastInputRoutingState = routingState }

        switch (lastInputRoutingState, routingState) {
        case (_, .preferredFallback):
            if lastInputRoutingState != routingState {
                notificationService.show(
                    title: "The Dictator",
                    body: "Preferred microphone unavailable. Using System Default input."
                )
            }
        case (.preferredFallback(let previousUID), .preferredAvailable(let currentUID)) where previousUID == currentUID:
            let selectedName = settingsStore.settings.preferredAudioInputName
            let display = selectedName.isEmpty ? "preferred microphone" : selectedName
            notificationService.show(
                title: "The Dictator",
                body: "Preferred microphone reconnected. Using \(display)."
            )
        default:
            break
        }
    }

    private func cancelInFlightOperations() {
        activeTranscriptionTask?.cancel()
        activeTranscriptionTask = nil
        transcriptionService.cancelInFlightTranscription()

        activeInsertionTask?.cancel()
        activeInsertionTask = nil

        audioCaptureService.discardCapture()
        recordingStartedAt = nil

        if let sessionID = activeSessionID {
            latencyTracker.clear(sessionID: sessionID)
        }
        activeSessionID = nil
    }

    private func mapTranscriptionWorkflowError(_ error: Error) -> AppWorkflowError {
        guard let transcriptionError = error as? TranscriptionError else {
            return .transcriptionFailed
        }

        switch transcriptionError {
        case .cancelled:
            return .cancelled
        case .modelPathMissing:
            return .backendMisconfigured(
                "Model path is missing. Open Settings → Transcription and set a local whisper model path."
            )
        case .modelPathInvalid(let path):
            return .backendMisconfigured(
                "Model path is invalid: \(path). Open Settings → Transcription and choose a valid model file."
            )
        case .modelNotInstalled(let modelID):
            return .backendMisconfigured(
                "Selected model \(modelID) is not installed. Open Settings → Transcription and download it in Model Manager."
            )
        case .executableNotFound(let name):
            return .backendMisconfigured(
                "\(name) is unavailable. Reinstall the app or use a build that includes the bundled transcription engine."
            )
        case .unsupportedBackend(let backend):
            return .backendMisconfigured(
                "Unsupported backend: \(backend). Set backend to whisper.cpp in Settings → Transcription."
            )
        case .backendLoadFailed(let message):
            return .backendMisconfigured("Backend failed to load: \(message)")
        case .timedOut, .emptyTranscript, .backendRuntimeFailed:
            return .transcriptionFailed
        }
    }

    private func mapInsertionWorkflowError(_ error: Error) -> AppWorkflowError {
        guard let insertionError = error as? TextInsertionError else {
            return .insertionFailed
        }

        switch insertionError {
        case .noActiveTarget:
            return .noActiveTarget
        case .accessibilityPermissionMissing:
            return .accessibilityDenied
        case .clipboardWriteFailed, .failedToCreatePasteEvents, .pasteLikelyFailed:
            return .insertionFailed
        }
    }
}
