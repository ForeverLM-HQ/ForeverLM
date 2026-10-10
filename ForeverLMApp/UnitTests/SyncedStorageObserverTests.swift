import Foundation
import Testing
@testable import ForeverLM

/// `SyncedStorage` replaced its `AppStorage` core because AppStorage re-rendered
/// its view on every `UserDefaults` write once a key contained a dot. These pin
/// the replacement's contract: the observer invalidates for its own key's value
/// changing, and for nothing else.
@MainActor
struct SyncedStorageObserverTests {
    private func withTemporaryKeys(_ body: (String, String) throws -> Void) rethrows {
        let key = "test.syncedStorage.\(UUID().uuidString)"
        let other = "test.syncedStorage.other.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: other)
        }
        try body(key, other)
    }

    @Test("a write to the observed key bumps the revision once")
    func ownKeyChangeInvalidates() {
        withTemporaryKeys { key, _ in
            let observer = SyncedStorageObserver(key: key)
            observer.startObservingIfNeeded()
            #expect(observer.revision == 0)

            UserDefaults.standard.set("compact", forKey: key)
            #expect(observer.revision == 1)

            UserDefaults.standard.set("roomy", forKey: key)
            #expect(observer.revision == 2)
        }
    }

    @Test("rewriting the same value is not a change")
    func identicalWriteDoesNotInvalidate() {
        withTemporaryKeys { key, _ in
            UserDefaults.standard.set(true, forKey: key)
            let observer = SyncedStorageObserver(key: key)
            observer.startObservingIfNeeded()

            UserDefaults.standard.set(true, forKey: key)
            // `Bool` and `Int` both land as NSNumber; 1 is the same stored value.
            UserDefaults.standard.set(1, forKey: key)
            #expect(observer.revision == 0)
        }
    }

    @Test("a write to another key is ignored")
    func unrelatedKeyDoesNotInvalidate() {
        withTemporaryKeys { key, other in
            let observer = SyncedStorageObserver(key: key)
            observer.startObservingIfNeeded()

            UserDefaults.standard.set(["chat*|reader"], forKey: other)
            UserDefaults.standard.set(42, forKey: other)
            #expect(observer.revision == 0)
        }
    }

    @Test("removing the key is a change, and removing it again is not")
    func removalInvalidatesOnce() {
        withTemporaryKeys { key, _ in
            UserDefaults.standard.set("x", forKey: key)
            let observer = SyncedStorageObserver(key: key)
            observer.startObservingIfNeeded()

            UserDefaults.standard.removeObject(forKey: key)
            #expect(observer.revision == 1)
            UserDefaults.standard.removeObject(forKey: key)
            #expect(observer.revision == 1)
        }
    }
}
