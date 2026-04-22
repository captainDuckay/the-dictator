import Foundation

enum WhisperModelLevel: String, Codable, CaseIterable {
    case tiny
    case base
    case small
    case medium
    case large
}

struct ManagedModelDescriptor: Codable, Equatable, Identifiable {
    let id: String
    let level: WhisperModelLevel
    let displayName: String
    let technicalName: String
    let diskBytes: Int64
    let estimatedRamBytes: Int64
    let downloadURL: URL?
    let sha256: String
    let version: String
    let bundled: Bool
    let minAppVersion: String
    let maxAppVersion: String?
}

struct ModelManifest: Codable, Equatable {
    let schemaVersion: Int
    let models: [ManagedModelDescriptor]
}
