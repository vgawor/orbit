import Foundation
import Security

/// Stores secrets (HubSpot and GitHub tokens) in the macOS Keychain.
///
/// Orbit is signed with a stable certificate, so the Keychain recognises it across rebuilds and
/// doesn't ask for permission. Values are cached in memory after the first read.
enum Secrets {
    private static let service = "com.viktorgawor.orbit.secrets"
    /// Where earlier versions kept tokens. Read once and moved to `service`.
    private static let oldService = "se.visualised.viktor.secrets"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    nonisolated(unsafe) private static var loaded: Set<String> = []

    /// True from launch until warmUp() has read the tokens (the app always calls it at startup).
    nonisolated(unsafe) private static var warming = true

    static func get(_ account: String) -> String? {
        lock.lock()
        if loaded.contains(account) { let v = cache[account]; lock.unlock(); return v }
        // While the background warm-up runs (it may be waiting on a Keychain prompt), never block the
        // main thread: answer "not available yet". Callers refresh once the warm-up finishes.
        if warming && Thread.isMainThread { lock.unlock(); return nil }
        lock.unlock()
        let value = read(account)
        lock.lock(); cache[account] = value; loaded.insert(account); lock.unlock()
        return value
    }

    /// Reads tokens into memory on the current (background) thread. If macOS asks for permission,
    /// only this thread waits; the app keeps working.
    static func warmUp(_ accounts: [String]) {
        lock.lock(); warming = true; lock.unlock()
        for account in accounts {
            let value = read(account)
            lock.lock(); cache[account] = value; loaded.insert(account); lock.unlock()
        }
        lock.lock(); warming = false; lock.unlock()
    }

    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let base = query(account)
        SecItemDelete(base as CFDictionary)
        loaded.insert(account)
        guard let value, !value.isEmpty else { cache[account] = nil; return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Orbit – \(account) token"
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        cache[account] = ok ? value : nil
        return ok
    }

    private static func query(_ account: String, service: String = service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> String? {
        if let value = read(account, from: service) { return value }
        // Not there yet: an earlier version may have it under the old name. Move it over.
        guard let old = read(account, from: oldService) else { return nil }
        var add = query(account)
        add[kSecValueData as String] = Data(old.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Orbit – \(account) token"
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
            SecItemDelete(query(account, service: oldService) as CFDictionary)
        }
        return old
    }

    private static func read(_ account: String, from service: String) -> String? {
        var q = query(account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Moving from the old file

    /// Earlier versions kept tokens in Application Support/Orbit/secrets.json. Moves them into the
    /// Keychain, checks they read back correctly, then deletes the file. Safe to call on every launch.
    static func migrateFromFile() -> Bool {
        let file = Storage.folder.appendingPathComponent("secrets.json")
        guard let data = try? Data(contentsOf: file),
              let old = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        var allMoved = true
        for (account, value) in old {
            set(value, for: account)
            lock.lock(); loaded.remove(account); lock.unlock()   // force a real read-back
            if get(account) != value { allMoved = false }
        }
        if allMoved { try? FileManager.default.removeItem(at: file) }
        return allMoved && !old.isEmpty
    }
}
