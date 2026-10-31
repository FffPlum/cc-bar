import Foundation
import CryptoKit

nonisolated enum APISecret {
    static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8192 && value.utf8.allSatisfy { (33...126).contains($0) }
    }
    static func fingerprint(_ value: String, namespace: String = "apiKey") -> String {
        SHA256.hash(data: Data((namespace + ":" + value).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct APISecretFileStore: Sendable {
    private let files: PrivateCredentialFileStore
    init(directory: URL) { files = PrivateCredentialFileStore(directory: directory) }
    func load(id: String) -> String? {
        guard let data = files.load(accountID: id, legacy: { nil }, validate: {
            String(data: $0, encoding: .utf8).map(APISecret.isValid) ?? false
        }) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func save(_ secret: String, id: String) throws {
        guard APISecret.isValid(secret) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        try files.save(Data(secret.utf8), accountID: id)
    }
    func delete(id: String) -> Bool { files.delete(accountID: id) }
}
