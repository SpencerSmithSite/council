// The secure half of lib/src/services/inference/inference_provider.dart:
// `_readKey`, `setCloudKey` and the `FlutterSecureStorage` they use.

import Foundation
import Security
import Synchronization

/// Where cloud API keys are kept: the reader's own credentials, so never in
/// `UserDefaults` or anywhere else in plain text on disk.
///
/// Synchronous, because the Keychain is; each call is a quick local lookup,
/// but keep it off the main actor on a hot path.
public protocol SecretStore: Sendable {
    /// The secret stored for `account`, or nil if there is none.
    func secret(for account: String) throws -> String?
    /// Stores `value` for `account`, replacing any; nil deletes it.
    func setSecret(_ value: String?, for account: String) throws
}

public extension SecretStore {
    /// The saved API key for `provider`, or empty.
    ///
    /// Empty when the store can't be read, too (a locked device, a missing
    /// entitlement): "no key" rather than a crash, as Dart's `_readKey` has it.
    /// The cloud backend then reports itself unavailable and says to add one.
    func apiKey(for provider: CloudProvider) -> String {
        (try? secret(for: provider.id)) ?? ""
    }

    /// Saves `key` for `provider`, trimmed; an empty key deletes the saved one
    /// (`setCloudKey`).
    func setAPIKey(_ key: String, for provider: CloudProvider) throws {
        let trimmed = DartText.trimmed(key)
        try setSecret(trimmed.isEmpty ? nil : trimmed, for: provider.id)
    }
}

/// A Keychain failure, with Security.framework's status code.
public struct KeychainError: Error, Hashable, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// The Keychain: generic passwords under service
/// `site.spencersmith.council.cloud`, one per provider, the account being the
/// provider id (`anthropic`, `openai`, `gemini`, `xai`).
///
/// Readable only while the device is unlocked and never synced or migrated to
/// another device (`WhenUnlockedThisDeviceOnly`): a key is the reader's to
/// re-enter on a new device, not something to scatter.
///
/// On the Mac it uses the login keychain, not the data-protection keychain.
/// The data-protection keychain needs a `keychain-access-groups` entitlement,
/// which needs a provisioning profile, and the Mac app is an unsandboxed
/// Developer ID build with none: saving a key failed with
/// `errSecMissingEntitlement` (-34018). The login keychain is where an
/// unsandboxed Mac app's passwords normally live, and items there are bound
/// to the app's code signature, so another app gets a prompt, not the key.
///
/// ## The Flutter app's items (for Phase 7, not migrated here)
///
/// `flutter_secure_storage` 9.2.4 with default Apple options stores each key
/// as a generic password with:
///
/// | Attribute | Flutter | Here |
/// |---|---|---|
/// | `kSecAttrService` | `flutter_secure_storage_service` | `site.spencersmith.council.cloud` |
/// | `kSecAttrAccount` | `api_key_<provider id>` (e.g. `api_key_anthropic`) | `<provider id>` |
/// | `kSecValueData` | the key as UTF-8 | the same |
/// | `kSecAttrAccessible` | `WhenUnlocked` | `WhenUnlockedThisDeviceOnly` |
/// | `kSecAttrSynchronizable` | false | false |
/// | `kSecUseDataProtectionKeychain` (macOS) | true | false (login keychain) |
///
/// Only the key for the provider selected at the time was ever read, but every
/// provider's key that was ever saved is there. Migration reads all four
/// `api_key_*` accounts under Flutter's service and saves them here. On the
/// Mac the Flutter app was sandboxed, so its items carry the sandboxed app's
/// access group; whether the unsandboxed native app (same team and bundle id)
/// can read them has to be checked on a real install (apple/PLAN.md, Phase 7).
public struct KeychainSecretStore: SecretStore {
    public static let cloudService = "site.spencersmith.council.cloud"

    /// `flutter_secure_storage`'s default service, for Phase 7.
    public static let flutterService = "flutter_secure_storage_service"

    /// `flutter_secure_storage`'s account name for a provider's key, for
    /// Phase 7.
    public static func flutterAccount(for provider: CloudProvider) -> String { "api_key_\(provider.id)" }

    public let service: String

    public init(service: String = KeychainSecretStore.cloudService) {
        self.service = service
    }

    public func secret(for account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func setSecret(_ value: String?, for account: String) throws {
        guard let value else {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(value.utf8)
        let update: [CFString: Any] = [kSecValueData: data]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
        #if os(iOS)
        // iOS has only the data-protection keychain; saying so is harmless
        // and keeps the query identical to what Flutter's plugin uses there.
        query[kSecUseDataProtectionKeychain] = true
        #endif
        return query
    }
}

/// Secrets in memory, for tests and previews.
public final class InMemorySecretStore: SecretStore {
    private let secrets: Mutex<[String: String]>

    public init(_ secrets: [String: String] = [:]) {
        self.secrets = Mutex(secrets)
    }

    public func secret(for account: String) throws -> String? {
        secrets.withLock { $0[account] }
    }

    public func setSecret(_ value: String?, for account: String) throws {
        secrets.withLock { $0[account] = value }
    }
}
