import Foundation

/// An in-memory copy of one preference for code that guards its state with a
/// lock.
///
/// The rule it packages: never touch defaults while holding a lock. A defaults
/// write posts `UserDefaults.didChangeNotification` on the writing thread, and
/// an observer on the main queue then waits for whoever holds the lock; a first
/// read blocks the thread on the preferences daemon. So the memo reads the
/// stored value once, outside its lock, publishes it under the lock, and on a
/// change updates the copy under the lock and persists after releasing it.
///
/// Reads after the first never reach defaults. A change made elsewhere (another
/// writer, an inbound sync) is not seen until `reload()`.
final class PreferenceMemo<Value>: @unchecked Sendable {
    private let lock = AppLock()
    private var loaded = false
    private var cached: Value?
    private let load: () -> Value
    private let persist: (Value) -> Void

    init(_ key: DeviceKey<Value>) {
        load = { Preferences.value(key) }
        persist = { Preferences.persist($0, for: key) }
    }

    #if os(macOS)
    init(_ key: AccountKey<Value>) {
        load = { Preferences.value(key) }
        persist = { Preferences.persist($0, for: key) }
    }
    #endif

    /// The value: the stored one on first use, the in-memory copy after.
    var value: Value {
        lock.lock()
        if loaded, let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        // Read with the lock released. Two first readers may both read; they
        // read the same stored value, and the first to publish wins.
        let stored = load()
        lock.lock()
        defer { lock.unlock() }
        if loaded, let cached { return cached }
        cached = stored
        loaded = true
        return stored
    }

    /// Replaces the value: the copy under the lock, the stored value after it
    /// is released.
    func set(_ newValue: Value) {
        lock.lock()
        cached = newValue
        loaded = true
        lock.unlock()
        persist(newValue)
    }

    /// Changes the value in one step under the lock, then persists the result
    /// after releasing it. `change` must not touch defaults or take this lock.
    @discardableResult
    func update(_ change: (inout Value) -> Void) -> Value {
        var current = value
        lock.lock()
        if let cached { current = cached }
        change(&current)
        cached = current
        loaded = true
        lock.unlock()
        persist(current)
        return current
    }

    /// Forgets the copy, so the next read takes the stored value again.
    func reload() {
        lock.lock()
        cached = nil
        loaded = false
        lock.unlock()
    }
}
