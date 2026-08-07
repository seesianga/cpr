import Foundation
import Security

enum KeychainStoreError: Error, Sendable, Equatable {
    case unexpectedStatus(Int32)
    case invalidItem
}

/// Actor-isolated generic-password Keychain store for the local session envelope.
actor KeychainStore: SessionStore {
    private let service: String
    private let accessGroup: String?

    init(service: String = "com.lifesaver.vision.session", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainStoreError.invalidItem
        }
        return data
    }

    func set(_ data: Data, for key: String) throws {
        let query = baseQuery(for: key)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }
    }

    func removeValue(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

/// Session-store test double that never touches the device Keychain.
actor InMemorySessionStore: SessionStore {
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? {
        values[key]
    }

    func set(_ data: Data, for key: String) {
        values[key] = data
    }

    func removeValue(for key: String) {
        values[key] = nil
    }
}
