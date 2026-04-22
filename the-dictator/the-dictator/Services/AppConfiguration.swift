import Foundation

enum AppConfiguration {
    static var modelManifestURL: URL {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "ModelManifestURL") as? String,
           let url = URL(string: configured),
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url
        }

        return URL(string: "https://github.com/captainDuckay/the-dictator-models/releases/latest/download/manifest.json")!
    }
}
