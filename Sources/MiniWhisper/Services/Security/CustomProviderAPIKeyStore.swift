import Foundation
import Security

private enum CustomProviderAPIKeyKind: String, Sendable {
    case transcription = "custom-transcription"
    case edit = "custom-edit"
}

enum CustomProviderAPIKeyStore {
    private static let service = "MiniWhisper Custom Provider API Keys"

    static func transcriptionKey() -> String {
        read(.transcription) ?? ""
    }

    @discardableResult
    static func saveTranscriptionKey(_ key: String) -> Bool {
        save(key, for: .transcription)
    }

    static func editKey() -> String {
        read(.edit) ?? ""
    }

    @discardableResult
    static func saveEditKey(_ key: String) -> Bool {
        save(key, for: .edit)
    }

    private static func read(_ kind: CustomProviderAPIKeyKind) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ key: String, for kind: CustomProviderAPIKeyKind) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return delete(kind) && read(kind) == nil
        }

        let encoded = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
        let update: [String: Any] = [
            kSecValueData as String: encoded,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        let saved: Bool
        if updateStatus == errSecSuccess {
            saved = true
        } else {
            guard updateStatus == errSecItemNotFound else { return false }

            var add = query
            add[kSecValueData as String] = encoded
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            saved = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }

        guard saved else { return false }
        return read(kind) == trimmed
    }

    private static func delete(_ kind: CustomProviderAPIKeyKind) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
