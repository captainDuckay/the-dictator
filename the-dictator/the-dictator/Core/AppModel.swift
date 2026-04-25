import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workflowSnapshotState: AppWorkflowState = .idle {
        didSet {
            AppLogger.info(AppLogger.workflow, "Workflow state changed: \(String(describing: workflowSnapshotState))")
            indicatorService.update(for: workflowSnapshotState)
        }
    }

    let settingsStore: SettingsStore
    let sessionStore: SessionStore
    let settingsModule: SettingsModule

    private let notificationService: NotificationService
    private let indicatorService: IndicatorService
    private let hotkeyService: HotkeyService?
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

        self.settingsModule = SettingsModule(
            settingsProvider: settingsStore,
            modelManager: modelManager,
            workflow: dictationWorkflow,
            permissionsService: permissionsService,
            notificationService: notificationService,
            audioInputProvider: audioInputDeviceService,
            capabilitiesProvider: transcriptionService
        )

        self.modelManager.onInventoryChanged = { [weak self] in
            self?.dictationWorkflow.refreshRuntimeReadiness()
        }

        notificationService.requestAuthorizationIfNeeded()
        permissionsService.runFirstLaunchChecksIfNeeded(notificationService: notificationService)
        bindDictationWorkflow()
        setupHotkeyCallbacks()
        bindSettings()
        registerPushToTalkHotkey()
        setupEscapeMonitoring()
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

    func pasteLastTranscript() {
        dictationWorkflow.pasteLastTranscript()
    }

    private func bindDictationWorkflow() {
        dictationWorkflow.$snapshot
            .sink { [weak self] snapshot in
                self?.workflowSnapshotState = snapshot.state
            }
            .store(in: &cancellables)

        dictationWorkflow.onOutcome = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .notification(let body):
                notificationService.show(title: "The Dictator", body: body)
            case .permissionStatusMayHaveChanged:
                settingsModule.refreshPermissionStatuses()
            }
        }
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
                guard let self else { return }
                AppLogger.diagnostic(AppLogger.workflow, "Hotkey callback: keyDown dispatched on MainActor")
                await self.dictationWorkflow.startDictation()
            }
        }

        hotkeyService?.onKeyUp = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                AppLogger.diagnostic(AppLogger.workflow, "Hotkey callback: keyUp dispatched on MainActor")
                self.dictationWorkflow.finishDictationHold()
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
}

extension SettingsStore: SettingsModuleSettingsProviding {
    var settingsPublisher: AnyPublisher<AppSettings, Never> {
        $settings.eraseToAnyPublisher()
    }
}

extension ModelManagerModule: SettingsModuleModelManaging {
    var snapshotPublisher: AnyPublisher<ModelManagerSnapshot, Never> {
        $snapshot.eraseToAnyPublisher()
    }
}

extension DictationWorkflow: SettingsModuleWorkflowProviding {
    var runtimeSnapshot: SettingsRuntimeSnapshot {
        SettingsRuntimeSnapshot(
            runtimeIssue: snapshot.runtimeIssue,
            modelRuntimePreflightDescription: snapshot.modelRuntimePreflightDescription
        )
    }

    var runtimeSnapshotPublisher: AnyPublisher<SettingsRuntimeSnapshot, Never> {
        $snapshot
            .map {
                SettingsRuntimeSnapshot(
                    runtimeIssue: $0.runtimeIssue,
                    modelRuntimePreflightDescription: $0.modelRuntimePreflightDescription
                )
            }
            .eraseToAnyPublisher()
    }
}

extension AudioInputDeviceService: SettingsModuleAudioInputProviding {
    var devicesPublisher: AnyPublisher<[AudioInputDevice], Never> {
        $devices.eraseToAnyPublisher()
    }
}

extension TranscriptionService: SettingsModuleCapabilitiesProviding {}
