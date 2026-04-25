import AppKit
import Combine
import Foundation

struct AudioInputOption: Identifiable, Equatable {
    let id: String
    let title: String
    let uid: String?
    let isUnavailable: Bool
}

struct SettingsRuntimeSnapshot: Equatable {
    var runtimeIssue: String?
    var modelRuntimePreflightDescription: String
}

@MainActor
protocol SettingsModuleSettingsProviding: AnyObject {
    var currentSettings: AppSettings { get }
    var settingsPublisher: AnyPublisher<AppSettings, Never> { get }
    func update(_ mutate: (inout AppSettings) -> Void)
}

@MainActor
protocol SettingsModuleModelManaging: AnyObject {
    var snapshot: ModelManagerSnapshot { get }
    var snapshotPublisher: AnyPublisher<ModelManagerSnapshot, Never> { get }

    func refreshModelCatalog(force: Bool)
    func refreshInstalledModels()
    func isModelInstalled(_ modelID: String) -> Bool
    func isModelUpdateAvailable(_ modelID: String) -> Bool
    func selectModel(id: String)
    func performRuntimeRecoveryAction()
    func downloadModel(id: String)
    func cancelModelDownload(id: String)
    func deleteModel(id: String)
    func modelLabel(for descriptor: ManagedModelDescriptor) -> String
    func modelResourceHint(for descriptor: ManagedModelDescriptor) -> String
    func modelVersionHint(for descriptor: ManagedModelDescriptor) -> String
    func canDeleteModel(_ modelID: String) -> Bool
    func modelStatus(for modelID: String) -> String
    func catalogRefreshDescription(relativeTo referenceDate: Date) -> String

    var onboardingHint: String? { get }
    var runtimeRecoveryActionTitle: String? { get }
}

@MainActor
protocol SettingsModuleWorkflowProviding: AnyObject {
    var runtimeSnapshot: SettingsRuntimeSnapshot { get }
    var runtimeSnapshotPublisher: AnyPublisher<SettingsRuntimeSnapshot, Never> { get }
    func refreshRuntimeReadiness(notifyIfNeeded: Bool)
}

@MainActor
protocol SettingsModuleAudioInputProviding: AnyObject {
    var devices: [AudioInputDevice] { get }
    var devicesPublisher: AnyPublisher<[AudioInputDevice], Never> { get }
    func refreshDevices()
    func inputDevice(forUID uid: String) -> AudioInputDevice?
}

@MainActor
protocol SettingsModuleCapabilitiesProviding: AnyObject {
    func capabilities(for backendType: String) throws -> BackendCapabilities
}

struct SettingsSnapshot: Equatable {
    var settings: AppSettings = AppSettings()

    var backendCapabilitiesDescription: String = "Unknown"
    var workflowRuntimePreflightDescription: String = "Checking bundled runtime assets…"
    var workflowRuntimeIssue: String?

    var modelManagerAvailableModels: [ManagedModelDescriptor] = []
    var modelManagerDownloadStates: [String: ModelDownloadState] = [:]
    var modelManagerStatusMessage: String?
    var modelManagerIsRefreshingCatalog: Bool = false
    var isUsingFallbackCatalog: Bool = false
    var modelManagerOnboardingHint: String?
    var runtimeRecoveryActionTitle: String?

    var audioInputOptions: [AudioInputOption] = []
    var selectedAudioInputOptionID: String = "systemDefault"
    var audioInputStatusDescription: String = "Following System Default input."

    var microphonePermissionStatus: String = "Unknown"
    var accessibilityPermissionStatus: String = "Unknown"
}

@MainActor
final class SettingsModule: ObservableObject {
    @Published private(set) var snapshot = SettingsSnapshot()

    private let settingsProvider: SettingsModuleSettingsProviding
    private let modelManager: SettingsModuleModelManaging
    private let workflow: SettingsModuleWorkflowProviding
    private let permissionsService: PermissionsService
    private let notificationService: NotificationService
    private let audioInputProvider: SettingsModuleAudioInputProviding
    private let capabilitiesProvider: SettingsModuleCapabilitiesProviding
    private let microphonePermissionStatusProvider: () -> String
    private let accessibilityPermissionGrantedProvider: () -> Bool

    private var cancellables = Set<AnyCancellable>()

    init(
        settingsProvider: SettingsModuleSettingsProviding,
        modelManager: SettingsModuleModelManaging,
        workflow: SettingsModuleWorkflowProviding,
        permissionsService: PermissionsService,
        notificationService: NotificationService,
        audioInputProvider: SettingsModuleAudioInputProviding,
        capabilitiesProvider: SettingsModuleCapabilitiesProviding,
        microphonePermissionStatusProvider: (() -> String)? = nil,
        accessibilityPermissionGrantedProvider: (() -> Bool)? = nil
    ) {
        self.settingsProvider = settingsProvider
        self.modelManager = modelManager
        self.workflow = workflow
        self.permissionsService = permissionsService
        self.notificationService = notificationService
        self.audioInputProvider = audioInputProvider
        self.capabilitiesProvider = capabilitiesProvider
        self.microphonePermissionStatusProvider = microphonePermissionStatusProvider ?? { permissionsService.microphonePermissionStatusDescription() }
        self.accessibilityPermissionGrantedProvider = accessibilityPermissionGrantedProvider ?? { permissionsService.isAccessibilityPermissionGranted() }

        bind()
        snapshot.settings = settingsProvider.currentSettings
        refreshBackendCapabilitiesDescription()
        refreshPermissionStatuses()
        refreshAudioInputState()
        applyModelManagerSnapshot(modelManager.snapshot)
        applyWorkflowSnapshot(workflow.runtimeSnapshot)
    }

    func updateSetting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>, _ newValue: Value) {
        settingsProvider.update { settings in
            settings[keyPath: keyPath] = newValue
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

        if !NSWorkspace.shared.open(settingsURL) {
            notificationService.show(title: "The Dictator", body: "Unable to open Microphone privacy settings.")
        }
    }

    func refreshPermissionStatuses() {
        snapshot.microphonePermissionStatus = microphonePermissionStatusProvider()
        snapshot.accessibilityPermissionStatus = accessibilityPermissionGrantedProvider() ? "Allowed" : "Not allowed"
    }

    func refreshAudioInputDevices() {
        audioInputProvider.refreshDevices()
        refreshAudioInputState()
    }

    func selectAudioInputOption(id: String) {
        if id == "systemDefault" {
            settingsProvider.update { settings in
                settings.audioInputPreference = .systemDefault
            }
            refreshAudioInputState()
            return
        }

        guard id.hasPrefix("device:") else { return }
        let uid = String(id.dropFirst("device:".count))
        let deviceName = audioInputProvider.inputDevice(forUID: uid)?.name ?? settingsProvider.currentSettings.preferredAudioInputName

        settingsProvider.update { settings in
            settings.audioInputPreference = .specificDevice(uid: uid)
            settings.preferredAudioInputName = deviceName
        }

        refreshAudioInputState()
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
        workflow.refreshRuntimeReadiness(notifyIfNeeded: false)
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

    func canDeleteModel(_ modelID: String) -> Bool {
        modelManager.canDeleteModel(modelID)
    }

    func modelStatus(for modelID: String) -> String {
        modelManager.modelStatus(for: modelID)
    }

    var modelManagerCatalogRefreshDescription: String {
        modelManager.catalogRefreshDescription(relativeTo: Date())
    }

    private func bind() {
        settingsProvider.settingsPublisher
            .sink { [weak self] settings in
                guard let self else { return }
                snapshot.settings = settings
                refreshBackendCapabilitiesDescription()
                refreshAudioInputState()
                workflow.refreshRuntimeReadiness(notifyIfNeeded: true)
            }
            .store(in: &cancellables)

        modelManager.snapshotPublisher
            .sink { [weak self] modelSnapshot in
                self?.applyModelManagerSnapshot(modelSnapshot)
            }
            .store(in: &cancellables)

        workflow.runtimeSnapshotPublisher
            .sink { [weak self] runtimeSnapshot in
                self?.applyWorkflowSnapshot(runtimeSnapshot)
            }
            .store(in: &cancellables)

        audioInputProvider.devicesPublisher
            .sink { [weak self] _ in
                self?.refreshAudioInputState()
            }
            .store(in: &cancellables)
    }

    private func applyModelManagerSnapshot(_ modelSnapshot: ModelManagerSnapshot) {
        snapshot.modelManagerAvailableModels = modelSnapshot.availableModels
        snapshot.modelManagerDownloadStates = modelSnapshot.downloadStates
        snapshot.modelManagerStatusMessage = modelSnapshot.statusMessage
        snapshot.modelManagerIsRefreshingCatalog = modelSnapshot.isRefreshingCatalog
        snapshot.isUsingFallbackCatalog = modelSnapshot.isUsingFallbackCatalog
        snapshot.modelManagerOnboardingHint = modelManager.onboardingHint
        snapshot.runtimeRecoveryActionTitle = modelManager.runtimeRecoveryActionTitle
    }

    private func applyWorkflowSnapshot(_ runtimeSnapshot: SettingsRuntimeSnapshot) {
        snapshot.workflowRuntimeIssue = runtimeSnapshot.runtimeIssue
        snapshot.workflowRuntimePreflightDescription = runtimeSnapshot.modelRuntimePreflightDescription
    }

    private func refreshBackendCapabilitiesDescription() {
        do {
            let capabilities = try capabilitiesProvider.capabilities(for: settingsProvider.currentSettings.backendType)
            let autoDetect = capabilities.supportsLanguageAutoDetect ? "yes" : "no"
            let explicitLanguage = capabilities.supportsExplicitLanguageSelection ? "yes" : "no"
            let cancellation = capabilities.supportsCancellation ? "yes" : "no"
            let timeout = Int(capabilities.defaultTimeoutSeconds)
            let notes = capabilities.notes.map { " | \($0)" } ?? ""

            snapshot.backendCapabilitiesDescription = "Auto-detect: \(autoDetect), language select: \(explicitLanguage), cancel: \(cancellation), timeout: \(timeout)s\(notes)"
        } catch {
            snapshot.backendCapabilitiesDescription = "Unavailable for backend: \(settingsProvider.currentSettings.backendType)"
        }
    }

    private func refreshAudioInputState() {
        let devices = audioInputProvider.devices
        let preference = settingsProvider.currentSettings.audioInputPreference
        let preferredName = settingsProvider.currentSettings.preferredAudioInputName

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

        snapshot.audioInputOptions = options

        switch preference {
        case .systemDefault:
            snapshot.selectedAudioInputOptionID = "systemDefault"
            snapshot.audioInputStatusDescription = "Following System Default input."
        case .specificDevice(let uid):
            snapshot.selectedAudioInputOptionID = "device:\(uid)"
            if let device = devices.first(where: { $0.uid == uid && $0.isAvailable }) {
                snapshot.audioInputStatusDescription = "Using \(device.name)."
            } else {
                snapshot.audioInputStatusDescription = "Currently using System Default until this device reconnects."
            }
        }
    }
}
