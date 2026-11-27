import Foundation
import Security

/// User-supplied module credentials, scoped to the selected peripheral. Never logged or exported.
enum BMSAccessStore {
    struct Access: Codable { var password: String; var mac: String }
    static func load(_ id: UUID) throws -> Access? {
        var query = base(id); query[kSecReturnData] = true; query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure.keychain(status) }
        return try JSONDecoder().decode(Access.self, from: data)
    }
    static func save(_ access: Access, id: UUID) throws {
        let data = try JSONEncoder().encode(access), query = base(id)
        let values: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            let added = SecItemAdd(query.merging(values) { _,new in new } as CFDictionary,nil)
            guard added == errSecSuccess else { throw Failure.keychain(added) }
        } else if result != errSecSuccess { throw Failure.keychain(result) }
    }
    static func remove(_ id: UUID) { SecItemDelete(base(id) as CFDictionary) }
    private static func base(_ id: UUID) -> [CFString: Any] {
        [kSecClass:kSecClassGenericPassword,kSecAttrService:"local.carwithin.bms.module-access",kSecAttrAccount:id.uuidString]
    }
    enum Failure: LocalizedError {
        case keychain(OSStatus)
        var errorDescription: String? { "无法读取或保存本机 BMS 登录信息，请解锁设备后重试。" }
    }
}
