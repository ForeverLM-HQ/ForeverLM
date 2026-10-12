import Foundation
import Testing
@testable import ForeverLM

/// The beta sign-up check (`AppUpdateController`) ran on every
/// `UserDefaults.didChangeNotification` and read the sign-up each time, so after
/// every window-frame save or Sparkle check date the main thread made
/// CFPreferences re-merge and re-diff the whole preferences domain. It now
/// listens through a `PreferenceKeyWatcher`, which reads only when the
/// preference store names its key. These pin both halves: the watcher fires on
/// its key's change, from this Mac or another, and on nothing else; and the
/// store announces its own writes by key.
@Suite("Preference key watcher")
@MainActor
struct PreferenceKeyWatcherTests {
    /// A stand-in for the stored value that counts its reads.
    final class Stored<Value> {
        var value: Value
        private(set) var reads = 0

        init(_ value: Value) {
            self.value = value
        }

        func read() -> Value {
            reads += 1
            return value
        }
    }

    /// Collects from observer blocks, which may not mutate a captured `var`.
    /// Touched on the main thread only: the observers run on the main queue.
    final class Box<Value>: @unchecked Sendable {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private func post(_ name: Notification.Name, keys: Set<String>?, on center: NotificationCenter) {
        center.post(name: name, object: nil, userInfo: keys.map { [PreferenceStore.changedKeysKey: $0] })
    }

    @Test("Signing up here calls back once with the new value, and a repeat of the same value does not")
    func localChangeOfTheBetaKeyCallsBack() {
        let center = NotificationCenter()
        let stored = Stored(false)
        let changes = Box<[Bool]>([])
        let watcher = PreferenceKeyWatcher(key: BetaReleases.preferenceKey, center: center, read: stored.read) {
            changes.value.append($0)
        }

        stored.value = true
        post(PreferenceStore.didChangeLocally, keys: [BetaReleases.preferenceKey], on: center)
        post(PreferenceStore.didChangeLocally, keys: [BetaReleases.preferenceKey], on: center)

        #expect(changes.value == [true])
        #expect(watcher.value == true)
    }

    @Test("Signing up or out on another Mac calls back")
    func remoteChangeOfTheBetaKeyCallsBack() {
        let center = NotificationCenter()
        let stored = Stored(false)
        let changes = Box<[Bool]>([])
        let watcher = PreferenceKeyWatcher(key: BetaReleases.preferenceKey, center: center, read: stored.read) {
            changes.value.append($0)
        }

        stored.value = true
        post(PreferenceStore.didChangeRemotely, keys: ["uiZoomStep", BetaReleases.preferenceKey], on: center)
        stored.value = false
        post(PreferenceStore.didChangeRemotely, keys: [BetaReleases.preferenceKey], on: center)

        #expect(changes.value == [true, false])
        #expect(watcher.value == false)
    }

    @Test("Changes to other keys, and every UserDefaults change notification, neither read nor call back")
    func unrelatedChangesAreNotRead() {
        let center = NotificationCenter()
        let stored = Stored(false)
        let changes = Box<[Bool]>([])
        let watcher = PreferenceKeyWatcher(key: BetaReleases.preferenceKey, center: center, read: stored.read) {
            changes.value.append($0)
        }
        #expect(stored.reads == 1)

        // Even a value that did move is not read until a change names its key.
        stored.value = true
        post(PreferenceStore.didChangeLocally, keys: ["studio.centerTabGroups.v1"], on: center)
        post(PreferenceStore.didChangeRemotely, keys: ["uiZoomStep", "map.layout.library"], on: center)
        center.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)

        #expect(stored.reads == 1)
        #expect(changes.value.isEmpty)
        #expect(watcher.value == false)
    }

    @Test("A real defaults write to another key is not heard at all")
    func realDefaultsWriteIsNotHeard() {
        let key = "test.preferenceKeyWatcher.\(UUID().uuidString)"
        let other = "test.preferenceKeyWatcher.other.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: other) }
        let stored = Stored(false)
        let changes = Box<[Bool]>([])
        let watcher = PreferenceKeyWatcher(key: key, read: stored.read) { changes.value.append($0) }

        // Posts UserDefaults.didChangeNotification on this, the main, thread.
        UserDefaults.standard.set(42, forKey: other)
        UserDefaults.standard.set("NSRect", forKey: other)

        #expect(stored.reads == 1)
        #expect(changes.value.isEmpty)
        #expect(watcher.value == false)
    }

    @Test("A remote change that names no keys reads once, and calls back only when the value moved")
    func keylessRemoteChangeRereads() {
        let center = NotificationCenter()
        let stored = Stored(false)
        let changes = Box<[Bool]>([])
        let watcher = PreferenceKeyWatcher(key: BetaReleases.preferenceKey, center: center, read: stored.read) {
            changes.value.append($0)
        }

        post(PreferenceStore.didChangeRemotely, keys: [], on: center)
        #expect(stored.reads == 2)
        #expect(changes.value.isEmpty)

        stored.value = true
        post(PreferenceStore.didChangeRemotely, keys: nil, on: center)
        #expect(stored.reads == 3)
        #expect(changes.value == [true])
        #expect(watcher.value == true)
    }

    @Test("The store announces its own writes by key, and a write that changes nothing not at all")
    func storeAnnouncesLocalWrites() {
        let key = "test.preferenceAnnouncement.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        // Nothing here reaches the sync rail.
        #expect(!SyncedPreferenceKeys.isSynced(key))
        let heard = Box<[Set<String>]>([])
        let token = NotificationCenter.default.addObserver(
            forName: PreferenceStore.didChangeLocally,
            object: nil,
            queue: .main
        ) { notification in
            let keys = notification.userInfo?[PreferenceStore.changedKeysKey] as? Set<String> ?? []
            if keys.contains(key) { heard.value.append(keys) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        PreferenceStore.set(true, forKey: key)
        PreferenceStore.set(true, forKey: key)
        PreferenceStore.remove(forKey: key)
        PreferenceStore.remove(forKey: key)
        // A `SyncedStorage` binding writes defaults itself, then mirrors.
        UserDefaults.standard.set("roomy", forKey: key)
        PreferenceStore.mirrorExternalWrite(forKey: key)

        #expect(heard.value == [[key], [key], [key]])
    }

    @Test("A watcher hears its key written and removed through the store, end to end")
    func watcherHearsTheStore() {
        let key = "test.preferenceKeyWatcher.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let changes = Box<[Bool]>([])
        let watcher = PreferenceKeyWatcher(key: key, read: { UserDefaults.standard.bool(forKey: key) }) {
            changes.value.append($0)
        }

        PreferenceStore.set(true, forKey: key)
        PreferenceStore.remove(forKey: key)

        #expect(changes.value == [true, false])
        #expect(watcher.value == false)
    }
}
