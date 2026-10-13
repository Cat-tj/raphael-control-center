import Foundation
import Security

/// Secrets (API keys, tokens) in the macOS Keychain, cached after the first read.
/// Items saved by the earlier Coucou-based build are copied over once.
final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()
    static let service = "id.altora.raphael-control-center"
    private static let legacyService = "fr.louisraille.NotchBuddy"

    private var cache: [String: String] = [:]
    private var misses: Set<String> = []
    private let lock = NSLock()

    func get(_ key: String) -> String? {
        if let v = lock.withLock({ cache[key] }) { return v }
        if lock.withLock({ misses.contains(key) }) { return nil }
        var value = Self.read(key, service: Self.service)
        if value == nil, let old = Self.read(key, service: Self.legacyService) {
            Self.write(key, old)
            value = old
        }
        lock.withLock { if let value { cache[key] = value } else { misses.insert(key) } }
        return value
    }

    func set(_ key: String, value: String) {
        lock.withLock { cache[key] = value; misses.remove(key) }
        Self.write(key, value)
    }

    func remove(_ key: String) {
        lock.withLock { cache[key] = nil; misses.insert(key) }
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: key] as CFDictionary)
    }

    private static func read(_ key: String, service: String) -> String? {
        var out: AnyObject?
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key,
                                  kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func write(_ key: String, _ value: String) {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData] = Data(value.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// OpenAI-compatible endpoint helpers.
enum LocalChat {
    /// "http://host:20128/v1/" → "http://host:20128" (the root the API paths hang off).
    static func normaliseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        for suffix in ["/api", "/v1"] where s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        return s
    }
}

/// One-time copy of settings from the Coucou-based build (other preferences domain).
enum SettingsMigration {
    static func run() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: "migratedFromNotchBuddy"), let old = UserDefaults(suiteName: "fr.louisraille.NotchBuddy") else { return }
        for (k, v) in old.dictionaryRepresentation() where k.hasPrefix("raphael") && ud.object(forKey: k) == nil {
            ud.set(v, forKey: k)
        }
        ud.set(true, forKey: "migratedFromNotchBuddy")
    }
}
