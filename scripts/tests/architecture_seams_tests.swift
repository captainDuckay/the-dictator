import Foundation

struct AppSettings {
    var selectedModelID: String = "base"
    var useCustomModelPath: Bool = false
    var customModelPath: String = ""
}

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
    let settings = InMemorySettingsProvider(currentSettings: AppSettings(selectedModelID: "zz-missing", useCustomModelPath: false, customModelPath: ""))

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

    let customMissing = AppSettings(selectedModelID: "base", useCustomModelPath: true, customModelPath: missingCustomPath)
    try assertContains(
        readiness.runtimeIssue(for: customMissing),
        "Custom model file is unavailable",
        "Expected custom path issue"
    )

    let notInstalled = AppSettings(selectedModelID: "zz-missing-model", useCustomModelPath: false, customModelPath: "")
    try assertContains(
        readiness.runtimeIssue(for: notInstalled),
        "Selected model zz-missing-model is not installed",
        "Expected missing selected model issue"
    )

    let installed = AppSettings(selectedModelID: "base", useCustomModelPath: false, customModelPath: "")
    try assertTrue(readiness.runtimeIssue(for: installed) == nil, "Expected nil runtime issue when executable + selected model are available")
}

@main
struct ArchitectureSeamTests {
    static func main() async {
        do {
            try await testModelManagerModuleSnapshotAndRecovery()
            try testRuntimeReadinessServiceIssues()
            print("✅ Architecture seam tests passed")
        } catch {
            print("❌ Architecture seam tests failed: \(error)")
            exit(1)
        }
    }
}
