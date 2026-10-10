#if DEBUG
import CloudKit
import OSLog
import SwiftUI

// `-foreverlm-uitest-space`: the Space's real screens over a library made on the spot, with no account
// and no iCloud, for a Simulator screenshot of the Space and for the Space's UI tests. The library is
// the real thing in miniature: a replica in memory with the personal library's zones and root, written
// through the phone's own generation-2 writer (`MobileRecordWriter`) and read by the real store, as the
// unit tests' fixtures make theirs. Only the server is stood in for: a transport that keeps each
// uploaded satellite in memory and answers every save, so a page's body uploads before its record names
// it exactly as it would. Nothing leaves the process.
//
// - `-foreverlm-uitest-space-page <name>` opens straight into a sample page: `krebs`, `membranes`,
//   `channels`, `reading`, `daily`, `site`, `google`, `team` or `trash`.
// - `-foreverlm-uitest-space-place <key>` opens a place: `all`, `pages`, `sites`, `drive`, `trash`, or
//   `lab`, the sample space.
// - `-foreverlm-uitest-space-sheet move-to-page` opens Move to Page… for the open page.
enum MobileSpaceHarness {
    static let launchArgument = "-foreverlm-uitest-space"
    static let pageArgument = "-foreverlm-uitest-space-page"
    static let placeArgument = "-foreverlm-uitest-space-place"
    static let sheetArgument = "-foreverlm-uitest-space-sheet"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// The value after `argument` on the launch line.
    static func value(of argument: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// The sample pages by the names the launch line uses.
    static let pageIDs: [String: String] = [
        "krebs": "harness-krebs",
        "membranes": "harness-membranes",
        "channels": "harness-channels",
        "reading": "harness-reading",
        "site": "harness-site",
        "google": "harness-google",
        "team": "harness-team",
        "trash": "harness-uncoupling",
    ]
}

/// The harness on screen: the Space as the phone or the split view draws it, once its library is made.
struct MobileSpaceHarnessView: View {
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "SpaceHarness")

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var library: MobileSpaceHarnessLibrary?
    @State private var failure: String?
    @State private var path: [MobileShellRoute] = []

    private static let notebookTitles = ["harness-notebook": "Mitochondria"]

    var body: some View {
        Group {
            if let library {
                space
                    .environment(library.store)
                    .environment(library.recents)
                    .environment(\.spaceNotebookTitles, Self.notebookTitles)
            } else if let failure {
                ContentUnavailableView("The sample library could not be made", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                let made = try await MobileSpaceHarnessLibrary.make()
                path = initialPath(made)
                library = made
            } catch {
                Self.logger.error("space harness: \(String(describing: error), privacy: .public)")
                failure = error.localizedDescription
            }
        }
        .accessibilityIdentifier("space.harness")
    }

    @ViewBuilder
    private var space: some View {
        if MobileSpaceLayout.usesSplitView(isRegularWidth: horizontalSizeClass == .regular,
                                           isRegularHeight: verticalSizeClass == .regular) {
            MobileSpaceSplitView(request: MobileSpaceCoverRequest(place: initialPlace ?? .all, pageID: initialPageID))
                .modifier(MobileSpaceHarnessSheet(pageID: initialPageID))
        } else {
            NavigationStack(path: $path) {
                MobileSpaceScreen(place: nil)
                    .navigationDestination(for: MobileShellRoute.self) { route in
                        switch route {
                        case .space(let place):
                            MobileSpaceScreen(place: place)
                        case .page(let pageID), .doc(let pageID, _):
                            MobilePageScreen(pageID: pageID)
                                .modifier(MobileSpaceHarnessSheet(pageID: pageID == initialPageID ? pageID : nil))
                        default:
                            Text("Not in the harness")
                        }
                    }
            }
            .environment(\.spaceNavigation, .stack($path))
            .environment(\.openURL, OpenURLAction { url in
                guard let link = MobileDeepLink.parse(url) else { return .systemAction }
                if case .doc = link {
                    path = MobileShellRoute.following(link, from: path, fromInsideApp: true)
                } else {
                    Self.logger.notice("follow \(url.absoluteString, privacy: .public)")
                }
                return .handled
            })
        }
    }

    private var initialPlace: MobileSpacePlace? {
        guard let key = MobileSpaceHarness.value(of: MobileSpaceHarness.placeArgument) else { return nil }
        if key == "lab", let lab = library?.labSpaceID { return .space(lab) }
        return MobileSpacePlace(key: key)
    }

    private var initialPageID: String? {
        guard let name = MobileSpaceHarness.value(of: MobileSpaceHarness.pageArgument) else { return nil }
        if name == "daily" { return DailyNote.id(for: Date()) }
        return MobileSpaceHarness.pageIDs[name] ?? name
    }

    /// The stack a launch line asks for on a phone: the sidebar, then the place, then the page.
    private func initialPath(_ made: MobileSpaceHarnessLibrary) -> [MobileShellRoute] {
        var routes: [MobileShellRoute] = []
        if let key = MobileSpaceHarness.value(of: MobileSpaceHarness.placeArgument) {
            routes.append(.space(key == "lab" ? .space(made.labSpaceID) : MobileSpacePlace(key: key)))
        }
        if let pageID = initialPageID { routes.append(.page(pageID)) }
        return routes
    }
}

/// `-foreverlm-uitest-space-sheet move-to-page`: Move to Page… over the page the launch line opened.
private struct MobileSpaceHarnessSheet: ViewModifier {
    let pageID: String?

    @Environment(MobileSpaceStore.self) private var store
    @State private var shown: MobileSpacePage?

    func body(content: Content) -> some View {
        content
            .sheet(item: $shown) { page in
                MobileSpaceParentPicker(page: page) { _ in }
                    .environment(store)
            }
            .task {
                guard MobileSpaceHarness.value(of: MobileSpaceHarness.sheetArgument) == "move-to-page", let pageID else { return }
                try? await Task.sleep(for: .milliseconds(600))
                shown = store.pages.first { $0.id == pageID }
            }
    }
}

// MARK: - The sample library

/// A library in memory, made through the phone's writer: a space, a page with two levels of subpages,
/// a pinned page, today's daily note, a site and a linked Google Doc, a team's page whose text has not
/// arrived, and a page in Trash.
@MainActor
final class MobileSpaceHarnessLibrary {
    let store: MobileSpaceStore
    let recents: MobileSpaceRecents
    let labSpaceID: String

    private init(store: MobileSpaceStore, recents: MobileSpaceRecents, labSpaceID: String) {
        self.store = store
        self.recents = recents
        self.labSpaceID = labSpaceID
    }

    /// Eight base32 characters, as every stamp's device id is.
    private static let deviceID = "harnessb"
    private static let librarySalt = Data(repeating: 3, count: 32)
    private static let teamSalt = Data(repeating: 7, count: 32)
    private static let teamZoneKey = "private/Space-acme"

    static func make() async throws -> MobileSpaceHarnessLibrary {
        let replica = try MobileReplica(path: ":memory:")
        let root = try rootRecord(["kind": .string("personal")], salt: librarySalt, in: PrivateSyncZones.library)
        let teamRoot = try rootRecord(["kind": .string("team"), "name": .string("Acme Lab"),
                                       "owner": SyncPerson(user: "harness", name: "Harness").value],
                                      salt: teamSalt, in: CloudZoneID("Space-acme"))
        try await replica.perform { state in
            for zone in PrivateSyncZones.all {
                try state.replica.upsertZone(ReplicaZone(zoneKey: PrivateSyncZones.key(zone), database: .private, zoneName: zone.zoneName,
                                                         kind: PrivateSyncZones.kind(zone), saltID: RecordNaming.saltID(librarySalt)))
            }
            try state.replica.upsertRecord(ReplicaRecord(root, zoneKey: PrivateSyncZones.libraryKey, wireID: SyncSchema.rootRecordName, seenPass: nil))
            try state.replica.upsertZone(ReplicaZone(zoneKey: teamZoneKey, database: .private, zoneName: "Space-acme", kind: "space",
                                                     role: "owner", permission: "readWrite", saltID: RecordNaming.saltID(teamSalt)))
            try state.replica.upsertRecord(ReplicaRecord(teamRoot, zoneKey: teamZoneKey, wireID: SyncSchema.rootRecordName, seenPass: nil))
            try state.replica.recordServerTime(Date(), sentAt: Date(), deviceID: deviceID)
            try state.replica.setEngineState(ReplicaStore.EngineScope.account, Data("harness".utf8))
        }

        var pacing = SyncPacerState.Configuration()
        pacing.capacity = 1_000_000
        pacing.refillPerSecond = 1_000_000
        let pacer = SyncPacer(configuration: pacing)
        let blobs = BlobStore(transport: MobileSpaceHarnessTransport(), store: replica, deviceID: deviceID, pacer: { _ in pacer })
        let clock = MobileSpaceHarnessClock()
        let writer = MobileRecordWriter(replica: replica, deviceID: deviceID, blobs: blobs, clock: { clock.now })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ForeverLMSpaceHarness-\(UUID().uuidString)", isDirectory: true)
        let satellites = MobileSatellites(projection: MobileProjection(replica: replica), blobs: blobs, disk: MobileSatelliteDisk(
            cacheRoot: folder.appendingPathComponent("cache", isDirectory: true),
            durableRoot: folder.appendingPathComponent("durable", isDirectory: true)
        ))
        let backend = MobileSpaceStore.Backend(writer: writer, satellites: satellites)
        let recents = MobileSpaceRecents(defaults: nil)
        let store = MobileSpaceStore(connect: { backend }, recents: recents)
        await store.refresh()

        // Made oldest first, each on its own day, so the lists read as a library that grew.
        let day: TimeInterval = 86_400
        clock.now = Date().addingTimeInterval(-40 * day)
        let lab = try await store.createSpace(named: "🧪 Lab")
        let krebs = try await store.createPage(title: "Krebs cycle", markdown: Samples.krebs, spaceID: lab, parentID: nil, id: "harness-krebs")
        clock.now = Date().addingTimeInterval(-21 * day)
        let membranes = try await store.createPage(title: "Membranes", markdown: Samples.membranes, spaceID: nil, parentID: krebs.id,
                                                   id: "harness-membranes")
        clock.now = Date().addingTimeInterval(-12 * day)
        _ = try await store.createPage(title: "Ion channels", markdown: Samples.channels, spaceID: nil, parentID: membranes.id,
                                       id: "harness-channels")
        clock.now = Date().addingTimeInterval(-9 * day)
        try await writer.transaction { write in
            try write.write(linkedPage("harness-site", kind: "site", title: "Bench lab site", url: "foreverlm-site://harness-site/"),
                            in: PrivateSyncZones.libraryKey)
            try write.write(linkedPage("harness-google", kind: "linkedDoc", title: "Lab protocol",
                                       url: "https://docs.google.com/document/d/1harness/edit"), in: PrivateSyncZones.libraryKey)
            var team = RecordPatch(.artifact, id: "harness-team")
            team.changes["kind"] = .value(.string("doc"))
            team.changes["title"] = .value(.string("Weekly sync notes"))
            team.changes["status"] = .value(.string("active"))
            team.changes["isDraft"] = .value(.bool(false))
            team.changes["createdAt"] = .value(SyncJSON(write.milliseconds))
            try write.write(team, in: teamZoneKey)
        }
        clock.now = Date().addingTimeInterval(-5 * day)
        let uncoupling = try await store.createPage(title: "Uncoupling proteins", markdown: Samples.uncoupling, spaceID: nil, parentID: nil,
                                                    id: "harness-uncoupling")
        clock.now = Date().addingTimeInterval(-2 * day)
        let reading = try await store.createPage(title: "Reading list", markdown: Samples.reading, spaceID: nil, parentID: nil,
                                                 id: "harness-reading")
        clock.now = Date().addingTimeInterval(-3 * 3600)
        let today = try await store.ensureDailyNote(dayKey: DailyNote.dayKey(for: Date()))
        try await store.saveBody(Samples.daily, of: today.id, expectedRevision: today.bodyRevision)
        clock.now = Date()

        try await store.moveToTrash(uncoupling.id)
        try await store.setPinned(reading.id, true)
        try await store.setPinned(krebs.id, true)
        recents.note(membranes.id, at: Date().addingTimeInterval(-600))
        recents.note(today.id, at: Date().addingTimeInterval(-300))
        recents.note(krebs.id)
        MobileSpaceExpansion.expand(krebs.id)
        await store.refresh()
        return MobileSpaceHarnessLibrary(store: store, recents: recents, labSpaceID: lab)
    }

    /// A linked page another device made: a site or a Google Doc, with no text copy.
    private static func linkedPage(_ id: String, kind: String, title: String, url: String) -> RecordPatch {
        var patch = RecordPatch(.artifact, id: id)
        patch.changes["kind"] = .value(.string(kind))
        patch.changes["title"] = .value(.string(title))
        patch.changes["linkedURL"] = .value(.string(url))
        patch.changes["status"] = .value(.string("active"))
        patch.changes["isDraft"] = .value(.bool(false))
        return patch
    }

    /// A zone's root as `SpaceService` and the seed make one (§2.4): its salt and its kind.
    private static func rootRecord(_ fields: [String: SyncJSON], salt: Data, in zone: CloudZoneID) throws -> CloudRecord {
        var all = fields
        let milliseconds = SyncTime.milliseconds(Date())
        all["salt"] = .string(salt.base64EncodedString())
        all["saltID"] = .string(RecordNaming.saltID(salt))
        all["createdAt"] = SyncJSON(milliseconds)
        all["editedAt"] = SyncJSON(milliseconds)
        all["minClientRevision"] = SyncJSON(1)
        var envelope = SyncEnvelope.new(.zoneRoot, id: SyncSchema.rootRecordName, saltID: RecordNaming.saltID(salt))
        var patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName)
        for (field, value) in all { patch.changes[field] = .value(value) }
        var counter = 0
        try envelope.apply(patch) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: milliseconds, counter: counter, deviceID: deviceID)
        }
        return CloudRecord(id: CloudRecordID(SyncSchema.rootRecordName, in: zone), recordType: SyncRecordType.zoneRoot.rawValue,
                           encryptedFields: [CloudRecord.payloadKey: .bytes(try envelope.storedPayload())])
    }

    private enum Samples {
        static let krebs = """
        The citric acid cycle turns acetyl-CoA into CO₂ and hands its electrons to NADH and FADH₂.

        ## The steps

        1. Citrate synthase joins acetyl-CoA to oxaloacetate.
        2. Aconitase turns citrate into isocitrate.
        3. Two decarboxylations give off CO₂ and make NADH.

        ## Where it goes next

        The electrons go to the [membranes](foreverlm://doc/harness-membranes), where the chain pumps protons.
        """

        static let membranes = """
        The inner membrane holds the electron transport chain. Its folds, the cristae, give it room.

        - Complex I and IV pump protons across it.
        - ATP synthase lets them back and makes ATP.
        """

        static let channels = """
        Ion channels let ions cross a membrane down their gradient, opened by voltage, a ligand or a stretch.
        """

        static let uncoupling = """
        UCP1 lets protons back in without making ATP: the gradient becomes heat.
        """

        static let reading = """
        - Mitchell, 1961: chemiosmotic coupling
        - Boyer: the binding change mechanism
        - Walker: the structure of F1
        """

        static let daily = """
        Read the Mitchell paper again. Questions:

        - Why does the gradient not leak?
        - What sets the P/O ratio?
        """
    }
}

/// The writer's clock, set back while the sample pages are made.
private final class MobileSpaceHarnessClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// The server, stood in for: every save is acknowledged and kept, so a satellite uploaded here is
/// there when it is looked up again; nothing is fetched by a change feed.
private final class MobileSpaceHarnessTransport: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: CloudRecord] = [:]

    let containerIdentifier = "iCloud.com.foreverlm.harness"

    func accountStatus() async throws -> CKAccountStatus { .available }

    func userRecordName() async throws -> String { "_harness" }

    func allZones(in database: CloudDatabaseScope) async throws -> [CloudZoneID] { [] }

    func modifyZones(saving: [CloudZoneID], deleting: [CloudZoneID], in database: CloudDatabaseScope) async throws -> CloudZoneModifyResults {
        CloudZoneModifyResults(saved: Dictionary(uniqueKeysWithValues: saving.map { ($0, .success(())) }),
                               deleted: Dictionary(uniqueKeysWithValues: deleting.map { ($0, .success(())) }))
    }

    func databaseChanges(in database: CloudDatabaseScope, since token: CloudChangeToken?, resultsLimit: Int?) async throws -> CloudDatabaseChanges {
        throw CloudError(.notAuthenticated, message: "The harness has no server.")
    }

    func zoneChanges(_ requests: [CloudZoneChangesRequest], in database: CloudDatabaseScope) async throws -> [CloudZoneID: Result<CloudZoneChanges, CloudError>] {
        [:]
    }

    func records(_ ids: [CloudRecordID], in database: CloudDatabaseScope, desiredKeys: [String]?) async throws -> [CloudRecordID: Result<CloudRecord, CloudError>] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, records[id.recordName].map { .success($0) } ?? .failure(CloudError(.unknownItem)))
            })
        }
    }

    func modifyRecords(saving: [CloudRecord], deleting: [CloudRecordID], in database: CloudDatabaseScope,
                       savePolicy: CloudSavePolicy, atomically: Bool) async throws -> CloudModifyResults {
        lock.withLock {
            var saved: [CloudRecordID: Result<CloudRecord, CloudError>] = [:]
            for record in saving {
                var held = record
                held.creationDate = held.creationDate ?? Date()
                records[record.id.recordName] = held
                saved[record.id] = .success(held)
            }
            var deleted: [CloudRecordID: Result<Void, CloudError>] = [:]
            for id in deleting {
                records[id.recordName] = nil
                deleted[id] = .success(())
            }
            return CloudModifyResults(saved: saved, deleted: deleted)
        }
    }
}
#endif
