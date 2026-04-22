import AppKit
import Foundation

@MainActor
final class AudioCueService {
    func playRecordingStarted(enabled: Bool) {
        guard enabled else { return }
        if NSSound(named: NSSound.Name("Tink"))?.play() == true {
            return
        }

        NSSound.beep()
    }

    func playRecordingStopped(enabled: Bool) {
        guard enabled else { return }
        if NSSound(named: NSSound.Name("Pop"))?.play() == true {
            return
        }

        NSSound.beep()
    }
}
