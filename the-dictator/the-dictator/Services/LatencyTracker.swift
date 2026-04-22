import Foundation

struct LatencySnapshot {
    let sessionID: UUID
    let captureToTranscriptMS: Int
    let transcriptToInsertMS: Int
    let totalCaptureToInsertMS: Int
}

@MainActor
final class LatencyTracker {
    private var captureEndedAt: [UUID: Date] = [:]
    private var transcriptReadyAt: [UUID: Date] = [:]

    func markCaptureEnded(sessionID: UUID) {
        captureEndedAt[sessionID] = Date()
    }

    func markTranscriptReady(sessionID: UUID) {
        transcriptReadyAt[sessionID] = Date()
    }

    func completeInsertion(sessionID: UUID) -> LatencySnapshot? {
        guard let captureEndedAt = captureEndedAt[sessionID], let transcriptReadyAt = transcriptReadyAt[sessionID] else {
            clear(sessionID: sessionID)
            return nil
        }

        let insertedAt = Date()
        let captureToTranscriptMS = Int(transcriptReadyAt.timeIntervalSince(captureEndedAt) * 1_000)
        let transcriptToInsertMS = Int(insertedAt.timeIntervalSince(transcriptReadyAt) * 1_000)
        let totalCaptureToInsertMS = Int(insertedAt.timeIntervalSince(captureEndedAt) * 1_000)

        clear(sessionID: sessionID)

        return LatencySnapshot(
            sessionID: sessionID,
            captureToTranscriptMS: captureToTranscriptMS,
            transcriptToInsertMS: transcriptToInsertMS,
            totalCaptureToInsertMS: totalCaptureToInsertMS
        )
    }

    func clear(sessionID: UUID) {
        captureEndedAt.removeValue(forKey: sessionID)
        transcriptReadyAt.removeValue(forKey: sessionID)
    }
}
