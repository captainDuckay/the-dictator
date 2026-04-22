import Combine
import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published var lastRecoverableTranscript: String?

    func saveRecoverableTranscript(_ transcript: String) {
        lastRecoverableTranscript = transcript
    }

    func clearRecoverableTranscript() {
        lastRecoverableTranscript = nil
    }
}
