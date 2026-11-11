import Foundation
import Security

/// Raw secure byte storage keyed by account name. Implemented by the Keychain and an in-memory store.
public protocol SecureStorage: Sendable {
    func data(for account: String) throws -> Data?
    func set(_ data: Data, for account: String) throws
    func remove(account: String) throws
}

/// Saves the server URL and API key. Backed by the Keychain by default.
public struct CredentialStore: Sendable {
    static let account = "server-credentials"

    private let storage: any SecureStorage

    public init(storage: any SecureStorage = KeychainStorage()) {
        self.storage = storage
    }

    /// The stored credentials, or `nil` if none are stored.
    public func load() throws -> ServerCredentials? {
        guard let data = try storage.data(for: Self.account) else { return nil }
        do {
            return try JSONDecoder().decode(ServerCredentials.self, from: data)
        } catch {
            throw CredentialStoreError.corruptData
        }
    }

    public func save(_ credentials: ServerCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try storage.set(data, for: Self.account)
    }

    public func clear() throws {
        try storage.remove(account: Self.account)
    }
}

public enum CredentialStoreError: Error, Sendable, Equatable {
    /// A Keychain call failed with this `OSStatus`.
    case keychain(OSStatus)
    /// Stored data could not be decoded.
    case corruptData
}

/// Generic-password Keychain items under one service name.
public struct KeychainStorage: SecureStorage {
    public static let defaultService = "no.immichkit.credentials"

    public let service: String

    public init(service: String = KeychainStorage.defaultService) {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func data(for account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychain(status)
        }
    }

    public func set(_ data: Data, for account: String) throws {
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
        default:
            throw CredentialStoreError.keychain(status)
        }
    }

    public func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }
}

/// Non-persistent storage for tests and previews.
public final class InMemorySecureStorage: SecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func data(for account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    public func set(_ data: Data, for account: String) throws {
        lock.withLock { items[account] = data }
    }

    public func remove(account: String) throws {
        lock.withLock { _ = items.removeValue(forKey: account) }
    }
}
