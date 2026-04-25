import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum AudioCaptureError: LocalizedError {
    case alreadyCapturing
    case notCapturing
    case noAudioCaptured
    case fileWriteFailed
    case failedToSelectInputDevice(status: OSStatus)
    case audioUnitUnavailable

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
        case .failedToSelectInputDevice(let status):
            return "Failed to select microphone device (status: \(status), fourCC: \(Self.fourCCString(for: status)))."
        case .audioUnitUnavailable:
            return "Failed to access audio input unit."
        }
    }

    private static func fourCCString(for status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let scalars: [UnicodeScalar] = [
            UnicodeScalar((value >> 24) & 0xFF),
            UnicodeScalar((value >> 16) & 0xFF),
            UnicodeScalar((value >> 8) & 0xFF),
            UnicodeScalar(value & 0xFF),
        ].compactMap { $0 }

        if scalars.count == 4,
           scalars.allSatisfy({ (32...126).contains(Int($0.value)) }) {
            return String(String.UnicodeScalarView(scalars))
        }

        return "0x\(String(value, radix: 16, uppercase: true))"
    }
}

@MainActor
final class AudioCaptureService {
    private let writeQueue = DispatchQueue(label: "the-dictator.audio-write")

    private var audioEngine: AVAudioEngine?
    private var activeInputNode: AVAudioInputNode?
    private var currentFile: AVAudioFile?
    private var currentCaptureURL: URL?
    private var capturedFrames: AVAudioFramePosition = 0

    private(set) var isCapturing = false

    func startCapture(deviceID: AudioDeviceID?) throws {
        guard !isCapturing else {
            throw AudioCaptureError.alreadyCapturing
        }

        cleanupAudioGraph()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if let deviceID {
            try setInputDevice(deviceID, on: inputNode)
        }

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
            engine.prepare()
            try engine.start()
            audioEngine = engine
            activeInputNode = inputNode
            isCapturing = true
            AppLogger.info(AppLogger.app, "Audio capture started. sampleRate=\(Int(inputFormat.sampleRate))Hz channels=\(inputFormat.channelCount)")
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            cleanupCurrentCaptureFile()
            throw error
        }
    }

    func stopCaptureAndExportWav() throws -> URL {
        guard isCapturing else {
            throw AudioCaptureError.notCapturing
        }

        activeInputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        isCapturing = false

        writeQueue.sync {}

        guard let outputURL = currentCaptureURL else {
            throw AudioCaptureError.fileWriteFailed
        }

        defer {
            currentFile = nil
            currentCaptureURL = nil
            capturedFrames = 0
            cleanupAudioGraph()
        }

        guard capturedFrames > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioCaptureError.noAudioCaptured
        }

        return outputURL
    }

    func discardCapture() {
        if isCapturing {
            activeInputNode?.removeTap(onBus: 0)
            audioEngine?.stop()
            isCapturing = false
        }

        cleanupCurrentCaptureFile()
        cleanupAudioGraph()
        capturedFrames = 0
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioCaptureError.audioUnitUnavailable
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw AudioCaptureError.failedToSelectInputDevice(status: status)
        }
    }

    private func cleanupAudioGraph() {
        activeInputNode = nil
        audioEngine = nil
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
