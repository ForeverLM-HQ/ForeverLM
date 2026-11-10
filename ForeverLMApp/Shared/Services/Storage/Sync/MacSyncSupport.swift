import CryptoKit
import Foundation
import OSLog
import Security

// MARK: - What a Mac's sync session needs to decide and say (docs/cloudkit-schema-design.md §13.3 to §13.6)

/// Whether a Mac may start syncing, and what it holds, from its activation's journal (§13.3 step 3, §13.4
/// step 1, §13.5). Pure: it reads no store.
enum CutoverReadiness: Equatable, Sendable {
    /// What the Mac holds for the seed: a library it may seed or reconcile, none, or a library of a store
    /// that never synced, which seeds at once only for a brand-new account.
    enum Holding: Equatable, Sendable {
        case library
        case none
        /// A `fresh` store with a library that never synced: it seeds at once when the account has no root and
        /// no `Knowledge` zone, else it uploads nothing until the learner confirms (§2.4).
        case libraryIfNewAccount
    }

    case notActivated
    /// A `deferred` store whose catch-up has not run: it sends nothing and takes no claim (WP16b2 runs it).
    case waitingForCatchUp
    /// A `fresh` store whose old zone was missing or whose guard was answered "Not this library": nothing
    /// is uploaded until the learner confirms "This Mac holds my library" (WP16c).
    case waitingForConfirmation
    case ready(Holding)

    /// `confirmedHoldsLibrary` is the learner's "This Mac holds my library" with its catch-up done
    /// (`HoldsMyLibrary.Standing.mayClaim`); `confirmationStarted` is a confirmation whose catch-up has not
    /// finished, which waits for the flow to resume (WP16c).
    static func decide(_ journal: CutoverJournal.Read, hasLibrary: Bool, confirmedHoldsLibrary: Bool, confirmationStarted: Bool = false) -> CutoverReadiness {
        guard journal.activatedAt != nil else { return .notActivated }
        switch journal.mode {
        case "full":
            return .ready(hasLibrary ? .library : .none)
        case "deferred":
            return journal.catchUpAt == nil ? .waitingForCatchUp : .ready(hasLibrary ? .library : .none)
        case "fresh":
            guard hasLibrary else { return .ready(.none) }
            if confirmedHoldsLibrary { return .ready(.library) }
            if confirmationStarted { return .waitingForConfirmation }
            if journal.freshReason == FreshReason.knowledgeMissing.rawValue { return .waitingForConfirmation }
            return .ready(.libraryIfNewAccount)
        default:
            return .notActivated
        }
    }

    /// The bootstrap client for a holding the lookup resolved: whether the old container still has a library.
    static func client(for holding: Holding, oldLibraryExists: Bool?) -> ZoneBootstrap.Client? {
        switch holding {
        case .library: return .macHoldingLibrary
        case .none: return .macWithoutLibrary
        case .libraryIfNewAccount:
            guard let oldLibraryExists else { return nil }
            return oldLibraryExists ? .macWithoutLibrary : .macHoldingLibrary
        }
    }
}

extension CutoverJournal {
    /// Whether the store holds a library: any row in `sources`, `learning_goals`, `review_sessions`,
    /// `global_artifacts` or `memory_items` (§13.3 step 1).
    static func holdsLibrary(_ connection: SQLiteConnection) throws -> Bool {
        for table in ["sources", "learning_goals", "review_sessions", "global_artifacts", "memory_items"] {
            if try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM \(table))") == 1 { return true }
        }
        return false
    }
}

extension LibraryClaimOutcome {
    /// What "This Mac holds my library" reports once it holds the root: the seed is this Mac's to run
    /// (claimed, resumed or taken over), the metadata is complete so it reconciles, or another Mac's live
    /// claim means try again later (§13.4 step 1, §13.5).
    static func forRoot(_ root: CutoverRootState, me: String, now: Int64) -> LibraryClaimOutcome {
        switch CutoverClaimDecision.decide(root, me: me, holdsLibrary: true, now: now) {
        case .resume, .claim, .takeOver, .noLibrary: return .seeding
        case .secondMac: return .reconciling
        case .wait: return .notYet
        }
    }
}

// MARK: - This installation's sync device id

/// The Mac's sync device id (§3.5.2): 8 base32 characters, random per installation, kept in a Keychain item
/// that stays on this Mac and never syncs. An isolated Development instance (its own data folder) gets an
/// id of its own, so two instances never stamp as one device. The replica's stamp clock names the id it
/// minted with and is taken back when the item is missing, so a Mac keeps one id for its stamps.
enum MacSyncDeviceID {
    static let service = "com.foreverlm.sync"
    /// Reserved for migrated history (§3.5.24), never drawn.
    static let reserved = "legacy22"
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    static var account: String {
        let folder = ForeverLMRuntimeIdentity.applicationSupportRootURL.standardizedFileURL.path
        return "deviceID.\(SHA256.hash(data: Data(folder.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined())"
    }

    static func current(clockDeviceID: String?) -> String {
        if let held = read(), isUsable(held) { return held }
        let id = clockDeviceID.flatMap { isUsable($0) ? $0 : nil } ?? draw()
        save(id)
        return id
    }

    /// The id this installation already holds, without drawing one: for saying which Mac this is
    /// (`get_mcp_status`) before or without sync, which alone mints it.
    static func stored() -> String? {
        read().flatMap { isUsable($0) ? $0 : nil }
    }

    static func isUsable(_ id: String) -> Bool {
        SyncStamp.isValidDeviceID(id) && id != reserved
    }

    static func draw() -> String {
        var generator = SystemRandomNumberGenerator()
        while true {
            let id = String((0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
            if isUsable(id) { return id }
        }
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    /// A unit-test host keeps the id in memory and never touches the Keychain: each build signs its
    /// host anew, so the Keychain asks whether that host may read the item, and the question waited
    /// forever behind a locked screen (2026-10-14, `get_mcp_status` in the full suite).
    private static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let testHeld = OSAllocatedUnfairLock<String?>(initialState: nil)

    private static func read() -> String? {
        if isTestHost { return testHeld.withLock { $0 } }
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ id: String) {
        if isTestHost {
            testHeld.withLock { $0 = id }
            return
        }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(id.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MacSyncSession")
                .error("The sync device id was not saved to the Keychain (\(status)); the replica's clock keeps it")
        }
    }
}

// MARK: - What the learner sees of the cutover

/// The cutover's progress, process-wide, for Settings › iCloud (WP16c) and the window's card: which phase
/// this Mac's seed is in, or whose seed it waits for. The session writes it; the main actor reads it.
final class CutoverStatus: @unchecked Sendable {
    static let shared = CutoverStatus()
    static let didChange = Notification.Name("ForeverLMCutoverStatusDidChange")

    enum State: Equatable, Sendable {
        case idle
        /// This Mac sends nothing and takes no claim until its catch-up has run (`deferred`).
        case waitingForCatchUp
        /// Until the learner confirms "This Mac holds my library".
        case waitingForConfirmation
        case seeding(CutoverSeedPhase)
        /// Another Mac seeds: "Your other Mac <name> is moving your library".
        case waitingForSeed(holder: String)
        case reconciling
        /// The seed stopped with a cause the learner is shown.
        case stopped(CutoverSeedStop)
        /// This Mac's part is done: the metadata is in and satellites follow.
        case moved
    }

    private let lock = NSLock()
    private var state = State.idle

    var current: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func update(_ new: State) {
        lock.lock()
        let changed = state != new
        state = new
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}

// MARK: - The hosted MCP's v2Ready

/// Tells the always-on MCP that the account's new root shows `seed.metadataCompleteAt` (`v2Ready`, §13.6):
/// the gateway's `POST /web/cloudkit/moved` with the learner's managed session, the endpoint the web's
/// `auto` check also uses. A no-op on a gateway still on generation 1. The tunnel provisioner's request is
/// not the carrier: the gateway keeps the account's hosted object, and its route takes the same bearer.
enum LibraryMovedReport {
    static let url = URL(string: "https://plugin.\(MCPBrandDomains.current)/web/cloudkit/moved")!

    static func request(sessionToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    /// Whether the gateway took the report (a 2xx), so the session reports once and tries again later when
    /// it did not.
    static func send(sessionToken: String?, session: URLSession = .shared) async -> Bool {
        guard let sessionToken else { return false }
        guard let (_, response) = try? await session.data(for: request(sessionToken: sessionToken)), let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
