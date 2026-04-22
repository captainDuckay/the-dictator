import Combine
import Foundation

enum AudioInputPreference: Codable, Equatable, Hashable {
    case systemDefault
    case specificDevice(uid: String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        if rawValue == "systemDefault" {
            self = .systemDefault
            return
        }

        if rawValue.hasPrefix("device:") {
            let uid = String(rawValue.dropFirst("device:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            self = uid.isEmpty ? .systemDefault : .specificDevice(uid: uid)
            return
        }

        self = .systemDefault
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .systemDefault:
            try container.encode("systemDefault")
        case .specificDevice(let uid):
            try container.encode("device:\(uid)")
        }
    }
}

struct AppSettings: Codable, Equatable {
    var pushToTalkHotkey: String = "Option + F8"
    var pasteLastTranscriptHotkey: String = "Shift + Option + F8"
    var backendType: String = "whisper.cpp"
    /// Legacy field kept for migration compatibility.
    var modelPath: String = ""
    var selectedModelID: String = "base"
    var useCustomModelPath: Bool = false
    var customModelPath: String = ""
    var languageAutoDetect: Bool = true
    var preferredLanguage: String = "en"
    var audioCuesEnabled: Bool = false
    var polishedOutputEnabled: Bool = true
    var audioInputPreference: AudioInputPreference = .systemDefault
    var preferredAudioInputName: String = ""

    private enum CodingKeys: String, CodingKey {
        case pushToTalkHotkey
        case pasteLastTranscriptHotkey
        case backendType
        case modelPath
        case selectedModelID
        case useCustomModelPath
        case customModelPath
        case languageAutoDetect
        case preferredLanguage
        case audioCuesEnabled
        case polishedOutputEnabled
        case audioInputPreference
        case preferredAudioInputName
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pushToTalkHotkey = try container.decodeIfPresent(String.self, forKey: .pushToTalkHotkey) ?? "Option + F8"
        pasteLastTranscriptHotkey = try container.decodeIfPresent(String.self, forKey: .pasteLastTranscriptHotkey) ?? "Shift + Option + F8"
        backendType = try container.decodeIfPresent(String.self, forKey: .backendType) ?? "whisper.cpp"
        modelPath = try container.decodeIfPresent(String.self, forKey: .modelPath) ?? ""
        selectedModelID = try container.decodeIfPresent(String.self, forKey: .selectedModelID) ?? "base"
        useCustomModelPath = try container.decodeIfPresent(Bool.self, forKey: .useCustomModelPath) ?? false
        customModelPath = try container.decodeIfPresent(String.self, forKey: .customModelPath) ?? ""
        languageAutoDetect = try container.decodeIfPresent(Bool.self, forKey: .languageAutoDetect) ?? true
        preferredLanguage = try container.decodeIfPresent(String.self, forKey: .preferredLanguage) ?? "en"
        audioCuesEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioCuesEnabled) ?? false
        polishedOutputEnabled = try container.decodeIfPresent(Bool.self, forKey: .polishedOutputEnabled) ?? true
        audioInputPreference = try container.decodeIfPresent(AudioInputPreference.self, forKey: .audioInputPreference) ?? .systemDefault
        preferredAudioInputName = try container.decodeIfPresent(String.self, forKey: .preferredAudioInputName) ?? ""
    }
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
        next.modelPath = normalized(next.modelPath, fallback: "")
        next.selectedModelID = normalized(next.selectedModelID, fallback: "base")
        next.customModelPath = normalized(next.customModelPath, fallback: "")
        next.preferredLanguage = normalized(next.preferredLanguage, fallback: "en")
        next.preferredAudioInputName = normalized(next.preferredAudioInputName, fallback: "")

        if !next.modelPath.isEmpty, next.customModelPath.isEmpty, FileManager.default.fileExists(atPath: next.modelPath) {
            next.useCustomModelPath = true
            next.customModelPath = next.modelPath
        }

        if next.useCustomModelPath, next.customModelPath.isEmpty {
            next.useCustomModelPath = false
        }

        if case .specificDevice(let uid) = next.audioInputPreference {
            let trimmedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
            next.audioInputPreference = trimmedUID.isEmpty ? .systemDefault : .specificDevice(uid: trimmedUID)
        }

        return next
    }

    private static func normalized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
