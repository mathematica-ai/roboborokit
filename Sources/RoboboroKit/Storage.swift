import Foundation

/// Persistent key-value store. Mirrors RN AsyncStorage keys.
public protocol RoboboroStoring: AnyObject, Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func remove(_ key: String)
    var isPersistent: Bool { get }
}

public final class RoboboroUserDefaultsStorage: RoboboroStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String

    public init(suiteName: String? = nil, prefix: String = "roboboro.") {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
        self.prefix = prefix
    }

    public var isPersistent: Bool { true }

    public func get(_ key: String) -> String? {
        defaults.string(forKey: prefix + key)
    }

    public func set(_ key: String, _ value: String) {
        defaults.set(value, forKey: prefix + key)
    }

    public func remove(_ key: String) {
        defaults.removeObject(forKey: prefix + key)
    }
}

public final class RoboboroMemoryStorage: RoboboroStoring, @unchecked Sendable {
    private var map: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public var isPersistent: Bool { false }

    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }

    public func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        map[key] = value
    }

    public func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        map.removeValue(forKey: key)
    }
}
