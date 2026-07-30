import Foundation
import Security

struct KeychainStore {
  private let service = "cz.cyberdjs.MailSurgeon"

  func save(password: String, account: String) throws {
    let data = Data(password.utf8)
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: true,
    ]

    SecItemDelete(base as CFDictionary)
    var insert = base
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

    let status = SecItemAdd(insert as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw KeychainStoreError.unhandled(status)
    }
  }

  func load(account: String) throws -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: true,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess else {
      throw KeychainStoreError.unhandled(status)
    }
    guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.invalidData
    }
    return password
  }
}

enum KeychainStoreError: Error {
  case invalidData
  case unhandled(OSStatus)
}
