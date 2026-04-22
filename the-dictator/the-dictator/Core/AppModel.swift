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

    private var cancellables = Set<AnyCancellable>()
    private var recordingStartedAt: Date?
    private var activeTranscriptionTask: Task<Void, Never>?
    private var activeInsertionTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var lastInputRoutingState: InputRoutingState?

    private enum InputRoutingState: Equatable {
        case systemDefault
        case preferredAvailable(uid: String)
        case preferredFallback(uid: String)
    }

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
        latencyTracker: LatencyTracker
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

        notificationService.requestAuthorizationIfNeeded()
        permissionsService.runFirstLaunchChecksIfNeeded(notificationService: notificationService)
        setupHotkeyCallbacks()
        bindSettings()
        registerPushToTalkHotkey()
        setupEscapeMonitoring()
        refreshPermissionStatuses()
        refreshBackendCapabilitiesDescription()
        refreshAudioInputState()
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
            latencyTracker: latencyTracker
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
                "\(name) is not installed or not in PATH. Install it (e.g. `brew install whisper-cpp`) or build whisper.cpp locally and add \(name) to PATH."
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
