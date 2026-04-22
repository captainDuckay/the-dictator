import Combine
import Foundation

struct AppSettings: Codable, Equatable {
    var pushToTalkHotkey: String = "Option + F8"
    var pasteLastTranscriptHotkey: String = "Shift + Option + F8"
    var backendType: String = "whisper.cpp"
    var modelPath: String = ""
    var languageAutoDetect: Bool = true
    var preferredLanguage: String = "en"
    var audioCuesEnabled: Bool = false
    var polishedOutputEnabled: Bool = true
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            save()
        }
    }

    private let defaults: UserDefaults
    private let storageKey = "the_dictator.settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        guard
            let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            self.settings = AppSettings()
            return
        }

        self.settings = Self.validated(decoded)
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var next = settings
        mutate(&next)
        settings = Self.validated(next)
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(settings) {
            defaults.set(encoded, forKey: storageKey)
            AppLogger.debug(AppLogger.settings, "Settings saved")
        } else {
            AppLogger.error(AppLogger.settings, "Failed to encode settings")
        }
    }

    private static func validated(_ settings: AppSettings) -> AppSettings {
        var next = settings

        let pushToTalkCandidate = normalized(next.pushToTalkHotkey, fallback: "Option + F8")
        next.pushToTalkHotkey = HotkeyParser.parse(pushToTalkCandidate) == nil ? "Option + F8" : pushToTalkCandidate

        let pasteCandidate = normalized(next.pasteLastTranscriptHotkey, fallback: "Shift + Option + F8")
        next.pasteLastTranscriptHotkey = HotkeyParser.parse(pasteCandidate) == nil ? "Shift + Option + F8" : pasteCandidate

        next.backendType = normalized(next.backendType, fallback: "whisper.cpp")
        next.preferredLanguage = normalized(next.preferredLanguage, fallback: "en")
        return next
    }

    private static func normalized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
