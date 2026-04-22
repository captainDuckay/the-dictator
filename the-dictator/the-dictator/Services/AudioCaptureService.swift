import AVFoundation
import Foundation

enum AudioCaptureError: LocalizedError {
    case alreadyCapturing
    case notCapturing
    case noAudioCaptured
    case fileWriteFailed

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            return "Audio capture is already running."
        case .notCapturing:
            return "Audio capture is not active."
        case .noAudioCaptured:
            return "No audio captured."
        case .fileWriteFailed:
            return "Failed to write captured audio."
        }
    }
}

@MainActor
final class AudioCaptureService {
    private let audioEngine = AVAudioEngine()
    private let writeQueue = DispatchQueue(label: "the-dictator.audio-write")

    private var currentFile: AVAudioFile?
    private var currentCaptureURL: URL?
    private var capturedFrames: AVAudioFramePosition = 0

    private(set) var isCapturing = false

    func startCapture() throws {
        guard !isCapturing else {
            throw AudioCaptureError.alreadyCapturing
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: inputFormat.settings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )

        currentFile = outputFile
        currentCaptureURL = outputURL
        capturedFrames = 0

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            self.writeQueue.sync {
                do {
                    try self.currentFile?.write(from: buffer)
                    self.capturedFrames += AVAudioFramePosition(buffer.frameLength)
                } catch {
                    AppLogger.error(AppLogger.app, "Audio write failed: \(error.localizedDescription)")
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isCapturing = true
        } catch {
            inputNode.removeTap(onBus: 0)
            cleanupCurrentCaptureFile()
            throw error
        }
    }

    func stopCaptureAndExportWav() throws -> URL {
        guard isCapturing else {
            throw AudioCaptureError.notCapturing
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isCapturing = false

        writeQueue.sync {}

        guard let outputURL = currentCaptureURL else {
            throw AudioCaptureError.fileWriteFailed
        }

        defer {
            currentFile = nil
            currentCaptureURL = nil
            capturedFrames = 0
        }

        guard capturedFrames > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioCaptureError.noAudioCaptured
        }

        return outputURL
    }

    func discardCapture() {
        if isCapturing {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            isCapturing = false
        }

        cleanupCurrentCaptureFile()
        capturedFrames = 0
    }

    private func cleanupCurrentCaptureFile() {
        let fileURL = currentCaptureURL
        currentFile = nil
        currentCaptureURL = nil

        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
