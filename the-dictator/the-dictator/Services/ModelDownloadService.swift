import Foundation

enum ModelDownloadError: LocalizedError {
    case downloadAlreadyInProgress(String)
    case invalidDownloadURL(String)
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .downloadAlreadyInProgress(let modelID):
            return "A model download is already in progress for \(modelID)."
        case .invalidDownloadURL(let modelID):
            return "Model \(modelID) does not provide a valid download URL."
        case .cancelled:
            return "Model download cancelled."
        case .failed(let message):
            return "Model download failed: \(message)."
        }
    }
}

enum ModelDownloadState: Equatable {
    case idle
    case downloading(progress: Double)
    case completed(tempFilePath: String)
    case failed(message: String)
}

final class ModelDownloadService: NSObject, URLSessionDownloadDelegate {
    private struct PendingDownload {
        let modelID: String
        let continuation: CheckedContinuation<URL, Error>
    }

    var onStateChange: ((_ modelID: String, _ state: ModelDownloadState) -> Void)?

    private let stateQueue = DispatchQueue(label: "captainDuckay.the-dictator.model-download-service")
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    private var modelStates: [String: ModelDownloadState] = [:]
    private var modelTasks: [String: URLSessionDownloadTask] = [:]
    private var taskToModelID: [Int: String] = [:]
    private var pendingByTaskID: [Int: PendingDownload] = [:]

    func downloadState(for modelID: String) -> ModelDownloadState {
        stateQueue.sync {
            modelStates[modelID] ?? .idle
        }
    }

    func startDownload(_ descriptor: ManagedModelDescriptor) async throws -> URL {
        guard let downloadURL = descriptor.downloadURL else {
            throw ModelDownloadError.invalidDownloadURL(descriptor.id)
        }

        return try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                if self.modelTasks[descriptor.id] != nil {
                    continuation.resume(throwing: ModelDownloadError.downloadAlreadyInProgress(descriptor.id))
                    return
                }

                let task = self.session.downloadTask(with: downloadURL)
                self.modelTasks[descriptor.id] = task
                self.taskToModelID[task.taskIdentifier] = descriptor.id
                self.pendingByTaskID[task.taskIdentifier] = PendingDownload(modelID: descriptor.id, continuation: continuation)
                self.updateState(modelID: descriptor.id, state: .downloading(progress: 0))
                task.resume()
            }
        }
    }

    func cancelDownload(modelID: String) {
        stateQueue.async {
            guard let task = self.modelTasks[modelID] else {
                return
            }

            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else {
            return
        }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        stateQueue.async {
            guard let modelID = self.taskToModelID[downloadTask.taskIdentifier] else {
                return
            }

            self.updateState(modelID: modelID, state: .downloading(progress: min(max(progress, 0), 1)))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        stateQueue.async {
            guard let pending = self.pendingByTaskID[downloadTask.taskIdentifier] else {
                return
            }

            do {
                let stableURL = try self.persistDownloadedFile(at: location, modelID: pending.modelID)
                self.updateState(modelID: pending.modelID, state: .completed(tempFilePath: stableURL.path))
                pending.continuation.resume(returning: stableURL)
            } catch {
                self.updateState(modelID: pending.modelID, state: .failed(message: error.localizedDescription))
                pending.continuation.resume(throwing: ModelDownloadError.failed(error.localizedDescription))
            }

            self.clearTracking(taskID: downloadTask.taskIdentifier, modelID: pending.modelID)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else {
            return
        }

        stateQueue.async {
            guard let pending = self.pendingByTaskID[task.taskIdentifier] else {
                return
            }

            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                self.updateState(modelID: pending.modelID, state: .idle)
                pending.continuation.resume(throwing: ModelDownloadError.cancelled)
            } else {
                self.updateState(modelID: pending.modelID, state: .failed(message: error.localizedDescription))
                pending.continuation.resume(throwing: ModelDownloadError.failed(error.localizedDescription))
            }

            self.clearTracking(taskID: task.taskIdentifier, modelID: pending.modelID)
        }
    }

    private func clearTracking(taskID: Int, modelID: String) {
        pendingByTaskID[taskID] = nil
        taskToModelID[taskID] = nil
        modelTasks[modelID] = nil
    }

    private func persistDownloadedFile(at location: URL, modelID: String) throws -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory.appendingPathComponent("the-dictator-model-downloads", isDirectory: true)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let destinationURL = baseDirectory.appendingPathComponent("\(modelID)-\(UUID().uuidString).bin", isDirectory: false)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: location, to: destinationURL)
        return destinationURL
    }

    private func updateState(modelID: String, state: ModelDownloadState) {
        modelStates[modelID] = state
        onStateChange?(modelID, state)
    }
}
