import CryptoKit
import Foundation

enum ModelIntegrityError: LocalizedError {
    case fileUnreadable(String)
    case hashMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .fileUnreadable(let path):
            return "Could not read downloaded model file: \(path)."
        case .hashMismatch(let expected, let actual):
            return "Model integrity check failed. Expected SHA-256 \(expected), got \(actual)."
        }
    }
}

final class ModelIntegrityService {
    private let chunkSize = 1024 * 1024

    func verifySHA256(fileURL: URL, expectedHex: String) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ModelIntegrityError.fileUnreadable(fileURL.path)
        }

        let actual = try sha256Hex(for: fileURL)
        let normalizedExpected = expectedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard actual == normalizedExpected else {
            throw ModelIntegrityError.hashMismatch(expected: normalizedExpected, actual: actual)
        }
    }

    private func sha256Hex(for fileURL: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw ModelIntegrityError.fileUnreadable(fileURL.path)
        }

        defer {
            try? handle.close()
        }

        var hasher = SHA256()

        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty {
                return false
            }

            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
