import Combine
import CoreAudio
import Foundation

enum AppWorkflowState: Equatable {
    case idle
    case recording
    case transcribing
    case inserting
    case error(AppWorkflowError)
}

enum AppWorkflowEvent: Equatable {
    case hotkeyDown(permissionsOK: Bool)
    case hotkeyUp(durationMS: Int)
    case transcriptionSucceeded(text: String)
    case transcriptionFailed(AppWorkflowError)
    case insertionSucceeded
    case insertionFailed(AppWorkflowError)
    case cancel
    case clearError
}

enum AppWorkflowError: LocalizedError, Equatable {
    case permissionsDenied
    case backendUnavailable
    case backendMisconfigured(String)
    case transcriptionFailed
    case insertionFailed
    case noActiveTarget
    case accessibilityDenied
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionsDenied:
            return "Required permissions are missing."
        case .backendUnavailable:
            return "Transcription backend is not configured yet."
        case .backendMisconfigured(let message):
            return message
        case .transcriptionFailed:
            return "Transcription failed."
        case .insertionFailed:
            return "Insertion failed. Use Paste Last Transcript to retry."
        case .noActiveTarget:
            return "No active text target was found. Use Paste Last Transcript after focusing a text field."
        case .accessibilityDenied:
            return "Accessibility permission is required for insertion."
        case .cancelled:
            return "Operation cancelled."
        }
    }
}

struct AppStateMachine {
    static let minimumHoldDurationMS = 250

    static func reduce(state: AppWorkflowState, event: AppWorkflowEvent) -> AppWorkflowState {
        switch (state, event) {
        case (.idle, .hotkeyDown(let permissionsOK)):
            return permissionsOK ? .recording : .idle

        case (.recording, .hotkeyUp(let durationMS)):
            return durationMS < minimumHoldDurationMS ? .idle : .transcribing

        case (.recording, .cancel):
            return .idle

        case (.transcribing, .transcriptionSucceeded):
            return .inserting

        case (.transcribing, .transcriptionFailed):
            return .idle

        case (.transcribing, .cancel):
            return .idle

        case (.inserting, .insertionSucceeded):
            return .idle

        case (.inserting, .insertionFailed):
            return .idle

        case (.inserting, .cancel):
            return .idle

        case (.error, .clearError):
            return .idle

        case (.error, .cancel):
            return .idle

        default:
            return state
        }
    }
}

struct DictationWorkflowSnapshot: Equatable {
    var state: AppWorkflowState
    var runtimeIssue: String?
    var modelRuntimePreflightDescription: String
    var hasRecoverableTranscript: Bool

    static let initial = DictationWorkflowSnapshot(
        state: .idle,
        runtimeIssue: nil,
        modelRuntimePreflightDescription: "Checking bundled runtime assets…",
        hasRecoverableTranscript: false
    )
}

enum DictationWorkflowOutcome: Equatable {
    case notification(String)
    case permissionStatusMayHaveChanged
}

@MainActor
final class DictationWorkflow: ObservableObject {
    @Published private(set) var snapshot: DictationWorkflowSnapshot = .initial

    var onOutcome: ((DictationWorkflowOutcome) -> Void)?

    private let settingsStore: SettingsStore
    private let sessionStore: SessionStore
    private let audioCaptureService: AudioCaptureService
    private let audioInputDeviceService: AudioInputDeviceService
    private let audioCueService: AudioCueService
    private let transcriptionService: TranscriptionService
    private let textInsertionService: TextInsertionService
    private let permissionsService: PermissionsService
    private let latencyTracker: LatencyTracker
    private let modelStoreService: ModelStoreService
    private let notificationService: NotificationService

    private var recordingStartedAt: Date?
    private var activeTranscriptionTask: Task<Void, Never>?
    private var activeInsertionTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var lastInputRoutingState: InputRoutingState?
    private var lastNotifiedRuntimeIssue: String?

    private enum InputRoutingState: Equatable {
        case systemDefault
        case preferredAvailable(uid: String)
        case preferredFallback(uid: String)
    }

    init(
        settingsStore: SettingsStore,
        sessionStore: SessionStore,
        audioCaptureService: AudioCaptureService,
        audioInputDeviceService: AudioInputDeviceService,
        audioCueService: AudioCueService,
        transcriptionService: TranscriptionService,
        textInsertionService: TextInsertionService,
        permissionsService: PermissionsService,
        latencyTracker: LatencyTracker,
        modelStoreService: ModelStoreService,
        notificationService: NotificationService
    ) {
        self.settingsStore = settingsStore
        self.sessionStore = sessionStore
        self.audioCaptureService = audioCaptureService
        self.audioInputDeviceService = audioInputDeviceService
        self.audioCueService = audioCueService
        self.transcriptionService = transcriptionService
        self.textInsertionService = textInsertionService
        self.permissionsService = permissionsService
        self.latencyTracker = latencyTracker
        self.modelStoreService = modelStoreService
        self.notificationService = notificationService
    }

    var canPasteLastTranscript: Bool {
        snapshot.hasRecoverableTranscript
    }

    func refreshRuntimeReadiness(notifyIfNeeded: Bool = true) {
        updateModelRuntimePreflightDescription()

        let settings = settingsStore.settings

        let issue: String?
        if !hasUsableWhisperExecutable() {
            issue = "Transcription engine is unavailable. Reinstall the app or add whisper-cli to PATH."
        } else if settings.useCustomModelPath {
            if settings.customModelPath.isEmpty || !FileManager.default.fileExists(atPath: settings.customModelPath) {
                issue = "Custom model file is unavailable. Choose a valid model file in Settings → Transcription."
            } else {
                issue = nil
            }
        } else if modelStoreService.localPath(for: settings.selectedModelID) == nil {
            issue = "Selected model \(settings.selectedModelID) is not installed. Open Settings → Transcription and download it in Model Manager."
        } else {
            issue = nil
        }

        snapshot.runtimeIssue = issue

        guard notifyIfNeeded else {
            return
        }

        if let issue, issue != lastNotifiedRuntimeIssue {
            onOutcome?(.notification(issue))
            lastNotifiedRuntimeIssue = issue
        } else if issue == nil {
            lastNotifiedRuntimeIssue = nil
        }
    }

    func startDictation() async {
        guard snapshot.state == .idle, activeSessionID == nil else {
            return
        }

        if let runtimeIssue = snapshot.runtimeIssue {
            onOutcome?(.notification(runtimeIssue))
            return
        }

        let hasPermission = await permissionsService.requestMicrophonePermissionForRecording(notificationService: notificationService)
        onOutcome?(.permissionStatusMayHaveChanged)

        guard hasPermission else {
            apply(.hotkeyDown(permissionsOK: false))
            onOutcome?(.notification(AppWorkflowError.permissionsDenied.errorDescription ?? "Missing permissions"))
            return
        }

        let captureRoute = resolveCaptureRoute()

        do {
            try audioCaptureService.startCapture(deviceID: captureRoute.deviceID)
            recordingStartedAt = Date()
            activeSessionID = UUID()
            apply(.hotkeyDown(permissionsOK: true))
            updateRouteNotifications(for: captureRoute.routingState)
            audioCueService.playRecordingStarted(enabled: settingsStore.settings.audioCuesEnabled)
        } catch {
            AppLogger.error(AppLogger.app, "Failed to start audio capture: \(error.localizedDescription)")
            onOutcome?(.notification("Couldn’t start recording with current microphone. Try reconnecting or choose another input in Settings."))
            audioCaptureService.discardCapture()
            cancelIfActive()
        }
    }

    func finishDictationHold() {
        guard snapshot.state == .recording, let sessionID = activeSessionID else {
            return
        }

        let durationMS = Int((Date().timeIntervalSince(recordingStartedAt ?? Date())) * 1_000)
        recordingStartedAt = nil
        audioCueService.playRecordingStopped(enabled: settingsStore.settings.audioCuesEnabled)

        if durationMS < AppStateMachine.minimumHoldDurationMS {
            audioCaptureService.discardCapture()
            activeSessionID = nil
            apply(.hotkeyUp(durationMS: durationMS))
            return
        }

        do {
            let outputURL = try audioCaptureService.stopCaptureAndExportWav()
            AppLogger.info(AppLogger.app, "Captured audio clip: \(outputURL.path)")

            latencyTracker.markCaptureEnded(sessionID: sessionID)
            apply(.hotkeyUp(durationMS: durationMS))
            startTranscription(audioURL: outputURL, sessionID: sessionID)
        } catch {
            AppLogger.error(AppLogger.app, "Failed to stop audio capture: \(error.localizedDescription)")
            onOutcome?(.notification("Failed to finalize recorded audio."))
            audioCaptureService.discardCapture()
            activeSessionID = nil
            cancelIfActive()
        }
    }

    func cancelIfActive() {
        guard snapshot.state == .recording || snapshot.state == .transcribing || snapshot.state == .inserting else {
            return
        }

        cancelInFlightOperations()
        apply(.cancel)
    }

    func pasteLastTranscript() {
        guard let transcript = sessionStore.lastRecoverableTranscript, !transcript.isEmpty else {
            onOutcome?(.notification("No recoverable transcript available."))
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

    private func apply(_ event: AppWorkflowEvent) {
        let nextState = AppStateMachine.reduce(state: snapshot.state, event: event)
        snapshot.state = nextState
        snapshot.hasRecoverableTranscript = !(sessionStore.lastRecoverableTranscript?.isEmpty ?? true)
    }

    private func startTranscription(audioURL: URL, sessionID: UUID) {
        guard snapshot.state == .transcribing, activeSessionID == sessionID else {
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
                snapshot.hasRecoverableTranscript = true
                AppLogger.info(AppLogger.app, "Transcript ready (\(result.backend)): \(result.text)")

                apply(.transcriptionSucceeded(text: result.text))
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
                apply(.transcriptionFailed(workflowError))

                if workflowError != .cancelled {
                    onOutcome?(.notification(workflowError.errorDescription ?? "Transcription failed"))
                }
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
           (snapshot.state != .inserting || activeSessionID == nil || activeSessionID != sessionID) {
            return
        }

        let hasAccessibility = permissionsService.ensureAccessibilityPermission(notificationService: notificationService)
        onOutcome?(.permissionStatusMayHaveChanged)
        guard hasAccessibility else {
            if useStateMachineInsertionState {
                apply(.insertionFailed(.accessibilityDenied))
                onOutcome?(.notification(AppWorkflowError.accessibilityDenied.errorDescription ?? "Accessibility denied"))
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
                    snapshot.hasRecoverableTranscript = false
                }

                if let sessionID, let latency = latencyTracker.completeInsertion(sessionID: sessionID) {
                    AppLogger.info(
                        AppLogger.app,
                        "Latency session \(latency.sessionID.uuidString): capture->transcript=\(latency.captureToTranscriptMS)ms transcript->insert=\(latency.transcriptToInsertMS)ms total=\(latency.totalCaptureToInsertMS)ms"
                    )
                }

                if useStateMachineInsertionState {
                    apply(.insertionSucceeded)
                    activeSessionID = nil
                }
            } catch {
                let workflowError = mapInsertionWorkflowError(error)
                AppLogger.error(AppLogger.app, "Insertion failed: \(workflowError.localizedDescription)")

                if useStateMachineInsertionState {
                    apply(.insertionFailed(workflowError))
                    if let sessionID {
                        latencyTracker.clear(sessionID: sessionID)
                    }
                    activeSessionID = nil
                }

                onOutcome?(.notification(workflowError.errorDescription ?? "Paste Last Transcript failed"))
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
                onOutcome?(.notification("Preferred microphone unavailable. Using System Default input."))
            }
        case (.preferredFallback(let previousUID), .preferredAvailable(let currentUID)) where previousUID == currentUID:
            let selectedName = settingsStore.settings.preferredAudioInputName
            let display = selectedName.isEmpty ? "preferred microphone" : selectedName
            onOutcome?(.notification("Preferred microphone reconnected. Using \(display)."))
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

    private func updateModelRuntimePreflightDescription() {
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
        snapshot.modelRuntimePreflightDescription = "\(cliStatus) • \(modelStatus)"
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

    private func hasUsableWhisperExecutable() -> Bool {
        if let bundledExecutable = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("whisper-cli", isDirectory: false),
           FileManager.default.isExecutableFile(atPath: bundledExecutable.path) {
            return true
        }

        let knownPaths = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/usr/bin/whisper-cli",
        ]

        if knownPaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return true
        }

        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for pathEntry in environmentPath.split(separator: ":") {
            let candidate = String(pathEntry) + "/whisper-cli"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return true
            }
        }

        return false
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
