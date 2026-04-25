import Combine
import Foundation

@MainActor
final class InMemorySettingsProvider: ModelManagerSettingsProviding {
    var currentSettings: AppSettings

    init(currentSettings: AppSettings) {
        self.currentSettings = currentSettings
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var next = currentSettings
        mutate(&next)
        currentSettings = next
    }
}

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("MockURLProtocol.requestHandler not set")
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

enum TestFailure: Error {
    case failed(String)
}

@MainActor
final class InMemorySettingsModuleProvider: SettingsModuleSettingsProviding {
    @Published private var settingsValue: AppSettings

    init(settings: AppSettings) {
        self.settingsValue = settings
    }

    var currentSettings: AppSettings { settingsValue }

    var settingsPublisher: AnyPublisher<AppSettings, Never> {
        $settingsValue.eraseToAnyPublisher()
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var next = settingsValue
        mutate(&next)
        settingsValue = next
    }
}

@MainActor
final class FakeModelManager: SettingsModuleModelManaging {
    @Published var currentSnapshot: ModelManagerSnapshot
    var onboardingHint: String?
    var runtimeRecoveryActionTitle: String?

    private(set) var didRefreshInstalledModels = false
    private(set) var lastRefreshForce: Bool?
    private(set) var didPerformRuntimeRecoveryAction = false

    init(snapshot: ModelManagerSnapshot, onboardingHint: String?, runtimeRecoveryActionTitle: String?) {
        self.currentSnapshot = snapshot
        self.onboardingHint = onboardingHint
        self.runtimeRecoveryActionTitle = runtimeRecoveryActionTitle
    }

    var snapshot: ModelManagerSnapshot { currentSnapshot }

    var snapshotPublisher: AnyPublisher<ModelManagerSnapshot, Never> {
        $currentSnapshot.eraseToAnyPublisher()
    }

    func refreshModelCatalog(force: Bool) {
        lastRefreshForce = force
    }

    func refreshInstalledModels() {
        didRefreshInstalledModels = true
    }

    func isModelInstalled(_ modelID: String) -> Bool {
        snapshot.installedModelIDs.contains(modelID)
    }

    func isModelUpdateAvailable(_ modelID: String) -> Bool {
        snapshot.updateAvailableModelIDs.contains(modelID)
    }

    func selectModel(id: String) {}
    func performRuntimeRecoveryAction() { didPerformRuntimeRecoveryAction = true }
    func downloadModel(id: String) {}
    func cancelModelDownload(id: String) {}
    func deleteModel(id: String) {}

    func modelLabel(for descriptor: ManagedModelDescriptor) -> String {
        "\(descriptor.displayName) (\(descriptor.technicalName))"
    }

    func modelResourceHint(for descriptor: ManagedModelDescriptor) -> String {
        "Disk: \(descriptor.diskBytes)"
    }

    func modelVersionHint(for descriptor: ManagedModelDescriptor) -> String {
        "Version: \(descriptor.version)"
    }

    func canDeleteModel(_ modelID: String) -> Bool {
        snapshot.installedModelIDs.contains(modelID)
    }

    func modelStatus(for modelID: String) -> String {
        snapshot.installedModelIDs.contains(modelID) ? "Installed" : "Not installed"
    }

    func catalogRefreshDescription(relativeTo referenceDate: Date) -> String {
        "Catalog refreshed"
    }
}

@MainActor
final class FakeWorkflowRuntimeProvider: SettingsModuleWorkflowProviding {
    @Published var currentRuntimeSnapshot: SettingsRuntimeSnapshot
    private(set) var refreshCalls: [Bool] = []

    init(runtimeSnapshot: SettingsRuntimeSnapshot) {
        self.currentRuntimeSnapshot = runtimeSnapshot
    }

    var runtimeSnapshot: SettingsRuntimeSnapshot { currentRuntimeSnapshot }

    var runtimeSnapshotPublisher: AnyPublisher<SettingsRuntimeSnapshot, Never> {
        $currentRuntimeSnapshot.eraseToAnyPublisher()
    }

    func refreshRuntimeReadiness(notifyIfNeeded: Bool) {
        refreshCalls.append(notifyIfNeeded)
    }
}

@MainActor
final class FakeAudioInputProvider: SettingsModuleAudioInputProviding {
    @Published var currentDevices: [AudioInputDevice]

    init(devices: [AudioInputDevice]) {
        self.currentDevices = devices
    }

    var devices: [AudioInputDevice] { currentDevices }

    var devicesPublisher: AnyPublisher<[AudioInputDevice], Never> {
        $currentDevices.eraseToAnyPublisher()
    }

    func refreshDevices() {}

    func inputDevice(forUID uid: String) -> AudioInputDevice? {
        currentDevices.first(where: { $0.uid == uid })
    }
}

final class FakeCapabilitiesProvider: SettingsModuleCapabilitiesProviding {
    var capabilitiesByBackend: [String: BackendCapabilities]

    init(capabilitiesByBackend: [String: BackendCapabilities]) {
        self.capabilitiesByBackend = capabilitiesByBackend
    }

    func capabilities(for backendType: String) throws -> BackendCapabilities {
        if let capabilities = capabilitiesByBackend[backendType] {
            return capabilities
        }
        throw TranscriptionError.unsupportedBackend(backendType)
    }
}

func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure.failed(message)
    }
}

func assertContains(_ value: String?, _ expectedSubstring: String, _ message: String) throws {
    guard let value, value.contains(expectedSubstring) else {
        throw TestFailure.failed("\(message). value=\(value ?? "nil")")
    }
}

@MainActor
func waitUntil(timeoutSeconds: TimeInterval = 2.0, _ predicate: @escaping () -> Bool) async throws {
    let start = Date()
    while !predicate() {
        if Date().timeIntervalSince(start) > timeoutSeconds {
            throw TestFailure.failed("Timed out waiting for async predicate")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor
func testModelManagerModuleSnapshotAndRecovery() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("the-dictator-seam-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let bundledModelURL = tempRoot.appendingPathComponent("base.bin", isDirectory: false)
    try Data("base-model".utf8).write(to: bundledModelURL)

    let modelStoreService = ModelStoreService()
    try modelStoreService.registerBundledModel(modelID: "base", version: "1.0.0", fileURL: bundledModelURL)

    let manifestURL = URL(string: "https://example.com/manifest.json")!
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)

    let manifestJSON = """
    {
      "schemaVersion": 1,
      "models": [
        {
          "id": "base",
          "level": "base",
          "displayName": "Balanced",
          "technicalName": "base",
          "diskBytes": 142000000,
          "estimatedRamBytes": 500000000,
          "downloadURL": null,
          "sha256": "",
          "version": "2.0.0",
          "bundled": true,
          "minAppVersion": "0.0.0",
          "maxAppVersion": null
        },
        {
          "id": "small",
          "level": "small",
          "displayName": "Higher Accuracy",
          "technicalName": "small",
          "diskBytes": 488000000,
          "estimatedRamBytes": 1300000000,
          "downloadURL": "https://example.com/small.bin",
          "sha256": "abc",
          "version": "1.0.0",
          "bundled": false,
          "minAppVersion": "0.0.0",
          "maxAppVersion": null
        }
      ]
    }
    """

    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, Data(manifestJSON.utf8))
    }

    let catalogService = ModelCatalogService(manifestURL: manifestURL, session: session)
    var initialSettings = AppSettings()
    initialSettings.selectedModelID = "zz-missing"
    initialSettings.useCustomModelPath = false
    initialSettings.customModelPath = ""
    let settings = InMemorySettingsProvider(currentSettings: initialSettings)

    let module = ModelManagerModule(
        settingsProvider: settings,
        modelStoreService: modelStoreService,
        modelCatalogService: catalogService,
        modelDownloadService: ModelDownloadService(),
        modelIntegrityService: ModelIntegrityService()
    )

    try await waitUntil {
        !module.snapshot.isRefreshingCatalog && !module.snapshot.availableModels.isEmpty
    }

    try assertTrue(module.snapshot.availableModels.count == 2, "Model catalog should expose two compatible models")
    try assertTrue(module.snapshot.updateAvailableModelIDs.contains("base"), "Base should be flagged as update available")
    try assertTrue(module.runtimeRecoveryActionTitle == "Use bundled base model", "Recovery action should prefer bundled base model")
}

@MainActor
func testSettingsModuleSnapshotAndIntents() async throws {
    var settings = AppSettings()
    settings.backendType = "whisper.cpp"
    settings.audioInputPreference = .systemDefault

    let settingsProvider = InMemorySettingsModuleProvider(settings: settings)

    let descriptor = ManagedModelDescriptor(
        id: "base",
        level: .base,
        displayName: "Balanced",
        technicalName: "base",
        diskBytes: 142_000_000,
        estimatedRamBytes: 500_000_000,
        downloadURL: nil,
        sha256: "",
        version: "1.0.0",
        bundled: true,
        minAppVersion: "0.0.0",
        maxAppVersion: nil
    )

    var modelSnapshot = ModelManagerSnapshot()
    modelSnapshot.availableModels = [descriptor]
    modelSnapshot.installedModelIDs = ["base"]

    let modelManager = FakeModelManager(
        snapshot: modelSnapshot,
        onboardingHint: "Balanced (base) is bundled and ready for offline dictation.",
        runtimeRecoveryActionTitle: "Use bundled base model"
    )

    let workflow = FakeWorkflowRuntimeProvider(
        runtimeSnapshot: SettingsRuntimeSnapshot(
            runtimeIssue: "Selected model is not installed.",
            modelRuntimePreflightDescription: "Bundled whisper-cli: ready • Bundled base model: ready"
        )
    )

    let audioProvider = FakeAudioInputProvider(devices: [
        AudioInputDevice(uid: "mic-default", name: "MacBook Mic", isAvailable: true, isSystemDefault: true, sampleRate: 48_000),
        AudioInputDevice(uid: "mic-usb", name: "USB Mic", isAvailable: true, isSystemDefault: false, sampleRate: 48_000),
    ])

    let capabilitiesProvider = FakeCapabilitiesProvider(capabilitiesByBackend: [
        "whisper.cpp": BackendCapabilities(
            supportsLanguageAutoDetect: true,
            supportsExplicitLanguageSelection: true,
            supportsCancellation: true,
            defaultTimeoutSeconds: 30,
            notes: "ok"
        )
    ])

    let module = SettingsModule(
        settingsProvider: settingsProvider,
        modelManager: modelManager,
        workflow: workflow,
        permissionsService: PermissionsService(),
        notificationService: NotificationService(),
        audioInputProvider: audioProvider,
        capabilitiesProvider: capabilitiesProvider
    )

    try assertTrue(module.snapshot.modelManagerAvailableModels.count == 1, "Expected one model in Settings snapshot")
    try assertContains(module.snapshot.backendCapabilitiesDescription, "Auto-detect: yes", "Expected capabilities description to be projected")
    try assertContains(module.snapshot.workflowRuntimeIssue, "not installed", "Expected runtime issue to be projected")

    module.updateSetting(\AppSettings.preferredLanguage, "fr")
    try await waitUntil {
        module.snapshot.settings.preferredLanguage == "fr"
    }

    module.selectAudioInputOption(id: "device:mic-usb")
    try assertTrue(module.snapshot.selectedAudioInputOptionID == "device:mic-usb", "Expected selected microphone to update")
    try assertContains(module.snapshot.audioInputStatusDescription, "Using USB Mic", "Expected microphone status to reflect selected device")

    module.performRuntimeRecoveryAction()
    try assertTrue(modelManager.didPerformRuntimeRecoveryAction, "Expected runtime recovery intent to call model manager")
    try assertTrue(workflow.refreshCalls.contains(false), "Expected runtime recovery to refresh workflow readiness without notification")

    module.refreshModelCatalog(force: true)
    try assertTrue(modelManager.lastRefreshForce == true, "Expected model catalog refresh intent to forward force=true")
}

@MainActor
func testSettingsModulePermissionStatusProjection() throws {
    let settingsProvider = InMemorySettingsModuleProvider(settings: AppSettings())
    let modelManager = FakeModelManager(snapshot: ModelManagerSnapshot(), onboardingHint: nil, runtimeRecoveryActionTitle: nil)
    let workflow = FakeWorkflowRuntimeProvider(
        runtimeSnapshot: SettingsRuntimeSnapshot(runtimeIssue: nil, modelRuntimePreflightDescription: "ready")
    )
    let audioProvider = FakeAudioInputProvider(devices: [])
    let capabilitiesProvider = FakeCapabilitiesProvider(capabilitiesByBackend: [:])

    var microphoneStatus = "Denied"
    var accessibilityGranted = false

    let module = SettingsModule(
        settingsProvider: settingsProvider,
        modelManager: modelManager,
        workflow: workflow,
        permissionsService: PermissionsService(),
        notificationService: NotificationService(),
        audioInputProvider: audioProvider,
        capabilitiesProvider: capabilitiesProvider,
        microphonePermissionStatusProvider: { microphoneStatus },
        accessibilityPermissionGrantedProvider: { accessibilityGranted }
    )

    module.refreshPermissionStatuses()
    try assertTrue(module.snapshot.microphonePermissionStatus == "Denied", "Expected projected microphone permission status")
    try assertTrue(module.snapshot.accessibilityPermissionStatus == "Not allowed", "Expected projected accessibility permission status")

    microphoneStatus = "Allowed"
    accessibilityGranted = true
    module.refreshPermissionStatuses()

    try assertTrue(module.snapshot.microphonePermissionStatus == "Allowed", "Expected refreshed microphone permission status")
    try assertTrue(module.snapshot.accessibilityPermissionStatus == "Allowed", "Expected refreshed accessibility permission status")
}

@MainActor
func testSettingsModuleRuntimeIssueProjectionTransitions() async throws {
    let settingsProvider = InMemorySettingsModuleProvider(settings: AppSettings())
    let modelManager = FakeModelManager(snapshot: ModelManagerSnapshot(), onboardingHint: nil, runtimeRecoveryActionTitle: nil)
    let workflow = FakeWorkflowRuntimeProvider(
        runtimeSnapshot: SettingsRuntimeSnapshot(runtimeIssue: nil, modelRuntimePreflightDescription: "ready")
    )
    let audioProvider = FakeAudioInputProvider(devices: [])
    let capabilitiesProvider = FakeCapabilitiesProvider(capabilitiesByBackend: [:])

    let module = SettingsModule(
        settingsProvider: settingsProvider,
        modelManager: modelManager,
        workflow: workflow,
        permissionsService: PermissionsService(),
        notificationService: NotificationService(),
        audioInputProvider: audioProvider,
        capabilitiesProvider: capabilitiesProvider
    )

    try assertTrue(module.snapshot.workflowRuntimeIssue == nil, "Expected no runtime issue initially")
    try assertTrue(module.snapshot.workflowRuntimePreflightDescription == "ready", "Expected initial runtime preflight description")

    workflow.currentRuntimeSnapshot = SettingsRuntimeSnapshot(
        runtimeIssue: "Selected model base is not installed.",
        modelRuntimePreflightDescription: "Bundled whisper-cli: missing"
    )

    try await waitUntil {
        module.snapshot.workflowRuntimeIssue == "Selected model base is not installed." &&
        module.snapshot.workflowRuntimePreflightDescription == "Bundled whisper-cli: missing"
    }

    workflow.currentRuntimeSnapshot = SettingsRuntimeSnapshot(
        runtimeIssue: nil,
        modelRuntimePreflightDescription: "Bundled whisper-cli: ready"
    )

    try await waitUntil {
        module.snapshot.workflowRuntimeIssue == nil &&
        module.snapshot.workflowRuntimePreflightDescription == "Bundled whisper-cli: ready"
    }
}

@MainActor
func testRuntimeReadinessServiceIssues() throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("the-dictator-readiness-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let installedModelURL = tempRoot.appendingPathComponent("base.bin")
    try Data("installed".utf8).write(to: installedModelURL)

    let store = ModelStoreService()
    try store.registerBundledModel(modelID: "base", version: "1.0.0", fileURL: installedModelURL)

    let missingCustomPath = tempRoot.appendingPathComponent("missing-custom.bin").path
    let readiness = RuntimeReadinessService(
        modelStoreService: store,
        fileExists: { path in
            if path == missingCustomPath { return false }
            return FileManager.default.fileExists(atPath: path)
        },
        executableExists: { _ in true },
        pathProvider: { "" }
    )

    var customMissing = AppSettings()
    customMissing.selectedModelID = "base"
    customMissing.useCustomModelPath = true
    customMissing.customModelPath = missingCustomPath
    try assertContains(
        readiness.runtimeIssue(for: customMissing),
        "Custom model file is unavailable",
        "Expected custom path issue"
    )

    var notInstalled = AppSettings()
    notInstalled.selectedModelID = "zz-missing-model"
    notInstalled.useCustomModelPath = false
    notInstalled.customModelPath = ""
    try assertContains(
        readiness.runtimeIssue(for: notInstalled),
        "Selected model zz-missing-model is not installed",
        "Expected missing selected model issue"
    )

    var installed = AppSettings()
    installed.selectedModelID = "base"
    installed.useCustomModelPath = false
    installed.customModelPath = ""
    try assertTrue(readiness.runtimeIssue(for: installed) == nil, "Expected nil runtime issue when executable + selected model are available")
}

@main
struct ArchitectureSeamTests {
    static func main() async {
        do {
            try await testModelManagerModuleSnapshotAndRecovery()
            try await testSettingsModuleSnapshotAndIntents()
            try testSettingsModulePermissionStatusProjection()
            try await testSettingsModuleRuntimeIssueProjectionTransitions()
            try testRuntimeReadinessServiceIssues()
            print("✅ Architecture seam tests passed")
        } catch {
            print("❌ Architecture seam tests failed: \(error)")
            exit(1)
        }
    }
}
