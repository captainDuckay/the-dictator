import AppKit
import Combine
import Foundation

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

    let settingsStore: SettingsStore
    let sessionStore: SessionStore

    private let notificationService: NotificationService
    private let indicatorService: IndicatorService
    private let hotkeyService: HotkeyService?
    private let audioCaptureService: AudioCaptureService
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

    init(
        settingsStore: SettingsStore,
        sessionStore: SessionStore,
        notificationService: NotificationService,
        indicatorService: IndicatorService,
        hotkeyService: HotkeyService?,
        audioCaptureService: AudioCaptureService,
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
    }

    convenience init() {
        let settingsStore = SettingsStore()
        let sessionStore = SessionStore()
        let notificationService = NotificationService()
        let indicatorService = IndicatorService()
        let audioCaptureService = AudioCaptureService()
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
    }

    private func registerPushToTalkHotkey() {
        guard let hotkeyService else {
            return
        }

        do {
            try hotkeyService.register(from: settingsStore.settings.pushToTalkHotkey)
        } catch {
            AppLogger.error(AppLogger.app, "Hotkey registration failed: \(error.localizedDescription)")
            notificationService.show(title: "The Dictator", body: "Failed to register push-to-talk hotkey.")
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

        do {
            try audioCaptureService.startCapture()
            recordingStartedAt = Date()
            activeSessionID = UUID()
            handle(.hotkeyDown(permissionsOK: true))
            audioCueService.playRecordingStarted(enabled: settingsStore.settings.audioCuesEnabled)
        } catch {
            AppLogger.error(AppLogger.app, "Failed to start audio capture: \(error.localizedDescription)")
            notificationService.show(title: "The Dictator", body: "Failed to start audio recording.")
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
        case .modelPathMissing, .modelPathInvalid, .backendLoadFailed, .executableNotFound, .unsupportedBackend:
            return .backendUnavailable
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
