import Foundation

enum ModelCatalogError: LocalizedError {
    case invalidManifestURL
    case networkFailed(String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidManifestURL:
            return "Model catalog URL is invalid."
        case .networkFailed(let message):
            return "Failed to fetch model catalog: \(message)."
        case .decodeFailed:
            return "Failed to decode model catalog manifest."
        }
    }
}

final class ModelCatalogService {
    private let session: URLSession
    private let manifestURL: URL

    init(manifestURL: URL, session: URLSession = .shared) {
        self.manifestURL = manifestURL
        self.session = session
    }

    func fetchManifest() async throws -> ModelManifest {
        do {
            let (data, response) = try await session.data(from: manifestURL)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw ModelCatalogError.networkFailed("HTTP \(http.statusCode)")
            }

            guard let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data) else {
                throw ModelCatalogError.decodeFailed
            }

            return manifest
        } catch let error as ModelCatalogError {
            throw error
        } catch {
            throw ModelCatalogError.networkFailed(error.localizedDescription)
        }
    }

    func compatibleModels(from manifest: ModelManifest, appVersion: String) -> [ManagedModelDescriptor] {
        manifest.models.filter { descriptor in
            isCompatible(descriptor: descriptor, appVersion: appVersion)
        }
    }

    private func isCompatible(descriptor: ManagedModelDescriptor, appVersion: String) -> Bool {
        if compareVersion(appVersion, descriptor.minAppVersion) == .orderedAscending {
            return false
        }

        if let maxVersion = descriptor.maxAppVersion,
           compareVersion(appVersion, maxVersion) == .orderedDescending {
            return false
        }

        return true
    }

    private func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let rhsParts = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhsParts.count, rhsParts.count)

        for index in 0..<count {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0

            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }

        return .orderedSame
    }
}
