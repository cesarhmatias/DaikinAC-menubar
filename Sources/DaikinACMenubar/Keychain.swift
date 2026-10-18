import Foundation
import Security

// Generic-password items under one service, as in LGwebOS-menubar's Keychain.swift (MIT).
// Holds user data only: the signed-in e-mail, the refresh token and the chosen device.
enum Keychain {
    static let service = "br.local.DaikinAC"

    enum Account: String {
        case session, selectedThing = "selected-thing"
    }

    private static func query(_ account: Account) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account.rawValue]
    }
    static func read(_ account: Account) -> Data? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func save(_ data: Data, as account: Account) throws {
        let q = query(account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = q; insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw DaikinError.message("Could not save to the Keychain (\(added)).") }
        } else if status != errSecSuccess { throw DaikinError.message("The Keychain refused the item (\(status)).") }
    }
    static func delete(_ account: Account) {
        SecItemDelete(query(account) as CFDictionary)
    }

    static func readString(_ account: Account) -> String? { read(account).flatMap { String(data: $0, encoding: .utf8) } }
    static func save(_ text: String, as account: Account) throws { try save(Data(text.utf8), as: account) }
}
