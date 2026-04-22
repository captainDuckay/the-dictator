import Foundation

struct InstalledModelRecord: Codable, Equatable, Identifiable {
    let modelID: String
    let version: String
    let localPath: String
    let installedAt: Date

    var id: String { "\(modelID):\(version)" }
}

private struct InstalledModelIndex: Codable, Equatable {
    var records: [InstalledModelRecord] = []
}

final class ModelStoreService {
    private let fileManager: FileManager
    private let modelsRootURL: URL
    private let indexURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)

        let appDirectory = appSupportURL
            .appendingPathComponent("TheDictator", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)

        self.modelsRootURL = appDirectory
        self.indexURL = appDirectory.appendingPathComponent("installed-models.json", isDirectory: false)

        do {
            try ensureStorageDirectories()
        } catch {
            AppLogger.error(AppLogger.settings, "Failed to prepare model storage: \(error.localizedDescription)")
        }
    }

    func localPath(for modelID: String) -> String? {
        latestRecord(for: modelID)?.localPath
    }

    func isInstalled(modelID: String, version: String? = nil) -> Bool {
        let records = loadIndex().records.filter { $0.modelID == modelID }

        guard let version else {
            return !records.isEmpty
        }

        return records.contains(where: { $0.version == version })
    }

    @discardableResult
    func install(tempFileURL: URL, descriptor: ManagedModelDescriptor) throws -> String {
        try ensureStorageDirectories()

        let destinationDirectory = modelsRootURL
            .appendingPathComponent(descriptor.id, isDirectory: true)
            .appendingPathComponent(descriptor.version, isDirectory: true)

        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let destinationURL = destinationDirectory.appendingPathComponent("model.bin", isDirectory: false)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: tempFileURL, to: destinationURL)

        var index = loadIndex()
        index.records.removeAll { $0.modelID == descriptor.id }
        index.records.append(
            InstalledModelRecord(
                modelID: descriptor.id,
                version: descriptor.version,
                localPath: destinationURL.path,
                installedAt: Date()
            )
        )
        try saveIndex(index)

        return destinationURL.path
    }

    func registerBundledModel(modelID: String, version: String, fileURL: URL) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        var index = loadIndex()
        index.records.removeAll { $0.modelID == modelID }
        index.records.append(
            InstalledModelRecord(
                modelID: modelID,
                version: version,
                localPath: fileURL.path,
                installedAt: Date()
            )
        )
        try saveIndex(index)
    }

    func delete(modelID: String) throws {
        var index = loadIndex()
        let toDelete = index.records.filter { $0.modelID == modelID }

        for record in toDelete {
            let fileURL = URL(fileURLWithPath: record.localPath, isDirectory: false)
            let isBundled = fileURL.path.hasPrefix(Bundle.main.bundlePath)
            if !isBundled, fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }

            if !isBundled {
                let versionDirectory = fileURL.deletingLastPathComponent()
                if fileManager.fileExists(atPath: versionDirectory.path) {
                    try? fileManager.removeItem(at: versionDirectory)
                }
            }
        }

        let modelDirectory = modelsRootURL.appendingPathComponent(modelID, isDirectory: true)
        if fileManager.fileExists(atPath: modelDirectory.path) {
            try? fileManager.removeItem(at: modelDirectory)
        }

        index.records.removeAll { $0.modelID == modelID }
        try saveIndex(index)
    }

    func allInstalled() -> [InstalledModelRecord] {
        loadIndex().records.sorted { lhs, rhs in
            if lhs.modelID == rhs.modelID {
                return lhs.installedAt > rhs.installedAt
            }
            return lhs.modelID < rhs.modelID
        }
    }

    private func latestRecord(for modelID: String) -> InstalledModelRecord? {
        loadIndex().records
            .filter { $0.modelID == modelID }
            .sorted(by: { $0.installedAt > $1.installedAt })
            .first
    }

    private func ensureStorageDirectories() throws {
        try fileManager.createDirectory(at: modelsRootURL, withIntermediateDirectories: true)
    }

    private func loadIndex() -> InstalledModelIndex {
        guard let data = try? Data(contentsOf: indexURL) else {
            return InstalledModelIndex()
        }

        return (try? JSONDecoder().decode(InstalledModelIndex.self, from: data)) ?? InstalledModelIndex()
    }

    private func saveIndex(_ index: InstalledModelIndex) throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: [.atomic])
    }
}
