import Foundation
import Security
import Testing
@testable import ForeverLM

#if os(macOS)
/// The vault is one Keychain item holding every local credential, rewritten
/// whole on each save. A read that failed for any reason other than "no such
/// item" used to read as an empty vault, and the next save then wrote a vault
/// holding only that one key. Each test runs on its own `VaultBackend`, so
/// neither the real Keychain nor another test's vault is touched.
@Suite("Keychain vault")
struct KeychainVaultTests {
    /// A Keychain stand-in: answers every read of the vault item with
    /// `vaultRead`, reports every other item absent, and records every write.
    private final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        var vaultRead: (status: OSStatus, data: Data?)
        private(set) var writes: [Data] = []

        init(vaultRead: (status: OSStatus, data: Data?)) {
            self.vaultRead = vaultRead
        }

        var writeCount: Int {
            lock.lock(); defer { lock.unlock() }
            return writes.count
        }

        var lastWrittenValues: [String: String]? {
            lock.lock(); defer { lock.unlock() }
            guard let data = writes.last,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["values"] as? [String: String]
        }

        func backend() -> KeychainService.VaultBackend {
            KeychainService.VaultBackend(
                copyMatching: { [self] query, result in
                    let attributes = query as NSDictionary
                    guard attributes[kSecAttrAccount as String] as? String == ForeverLMRuntimeIdentity.keychainVaultAccount,
                          attributes[kSecAttrSynchronizable as String] == nil else {
                        return errSecItemNotFound
                    }
                    if let data = vaultRead.data { result?.pointee = data as CFData }
                    return vaultRead.status
                },
                update: { [self] _, attributes in
                    record(attributes)
                    return errSecSuccess
                },
                add: { [self] attributes, _ in
                    record(attributes)
                    return errSecSuccess
                }
            )
        }

        private func record(_ attributes: CFDictionary) {
            let data = (attributes as NSDictionary)[kSecValueData as String] as? Data ?? Data()
            lock.lock(); defer { lock.unlock() }
            writes.append(data)
        }
    }

    private static func vaultData(_ values: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "values": values])
    }

    /// Not synced and not a preference, so it lives in the vault alone.
    private static let key = KeychainService.Key.anthropicAPIKey

    @Test("A vault the Keychain cannot read while locked is never written over")
    func lockedVaultIsNotWrittenOver() {
        let keychain = FakeKeychain(vaultRead: (errSecInteractionNotAllowed, nil))

        KeychainService.$vaultBackend.withValue(keychain.backend()) {
            KeychainService.save("sk-test-new", for: Self.key)
            #expect(KeychainService.load(Self.key) == nil)
            #expect(throws: KeychainService.VaultUnavailableError.self) {
                try KeychainService.loadIfReadable(Self.key)
            }
            KeychainService.save("sk-test-again", for: Self.key)
        }

        #expect(keychain.writeCount == 0)
    }

    @Test("A vault payload this build cannot decode is never written over")
    func undecodableVaultIsNotWrittenOver() {
        let keychain = FakeKeychain(vaultRead: (errSecSuccess, Data("not a vault".utf8)))

        let thrown = KeychainService.$vaultBackend.withValue(keychain.backend()) { () -> Error? in
            KeychainService.save("sk-test-new", for: Self.key)
            do {
                _ = try KeychainService.loadIfReadable(Self.key)
                return nil
            } catch {
                return error
            }
        }

        #expect((thrown as? KeychainService.VaultUnavailableError)?.status == errSecDecode)
        #expect(keychain.writeCount == 0)
    }

    @Test("Once the vault reads, a save keeps every credential it held")
    func saveAfterUnlockKeepsEveryCredential() throws {
        let stored = ["openai_api_key": "sk-test-openai", "mcp_oauth_client_secret": "secret-test"]
        let keychain = FakeKeychain(vaultRead: (errSecInteractionNotAllowed, nil))
        let backend = keychain.backend()

        try KeychainService.$vaultBackend.withValue(backend) {
            KeychainService.save("sk-test-locked", for: Self.key)
            #expect(keychain.writeCount == 0)

            // The Mac unlocks: the same backend reads the vault this time.
            // (A read of the still-missing key would go on to the individual
            // items, which are the real Keychain's, so the test only saves.)
            keychain.vaultRead = (errSecSuccess, try Self.vaultData(stored))
            KeychainService.save("sk-test-new", for: Self.key)
            #expect(KeychainService.load(Self.key) == "sk-test-new")
        }

        var expected = stored
        expected[Self.key.rawValue] = "sk-test-new"
        #expect(keychain.writeCount == 1)
        #expect(keychain.lastWrittenValues == expected)
    }
}
#endif
