import Foundation
import Security

struct StationLinkKeyResponse: Decodable {
    let version: Int
    let key: String
}

extension APIClient {
    /// GET /api/me/station-link-key — this account's iPad Station link secret.
    func stationLinkKey(jwt: String) async throws -> StationLinkKeyResponse {
        try await get("api/me/station-link-key", jwt: jwt)
    }
}

/// Keeps each account's link secret in this device's Keychain, so a gym with
/// no signal can still pair once the key was fetched online. Station views get
/// only a loader closure, never an API client.
enum StationLinkKeyStore {
    private static let service = "com.nmarkspdx.tresfort.station-link"

    /// A cached key is used at once, so a weak gym connection never delays
    /// the link; the server copy refreshes it in the background.
    static func load(accountID: String, jwt: String?) async -> Data? {
        guard !accountID.isEmpty else { return nil }
        if let key = cached(accountID: accountID) {
            if let jwt { Task { _ = await fetch(accountID: accountID, jwt: jwt) } }
            return key
        }
        guard let jwt else { return nil }
        return await fetch(accountID: accountID, jwt: jwt)
    }

    private static func fetch(accountID: String, jwt: String) async -> Data? {
        guard let response = try? await APIClient().stationLinkKey(jwt: jwt),
              response.version == StationLink.keyVersion,
              let key = Data(base64Encoded: response.key), key.count == 32 else { return nil }
        save(key, accountID: accountID)
        return key
    }

    private static func query(_ accountID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: accountID]
    }

    private static func save(_ key: Data, accountID: String) {
        guard cached(accountID: accountID) != key else { return }
        SecItemDelete(query(accountID) as CFDictionary)
        var add = query(accountID)
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func cached(accountID: String) -> Data? {
        var lookup = query(accountID)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return data
    }
}
