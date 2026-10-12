import Foundation
import OSLog

/// The kinds of file a light client hands a Mac with `Job(ingestFile)` (§5.4, D47): a PDF (`capture`
/// scan, photos, pdf, or share), an EPUB or a text file (`capture: share` with `fileKind`).
enum JobFileKind: String, Sendable {
    case pdf
    case epub
    case text

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .epub: return "epub"
        case .text: return "txt"
        }
    }
}

/// What a Mac does for each kind of Job (§3.5.28), through the Mac's own import paths and tool
/// handlers. The app's is `StudioJobWork`; the suites give their own.
protocol MacJobWork: Sendable {
    /// Imports an address into the library as the Mac's own link import does; the source's id when the
    /// import knows it.
    func importLink(_ url: String) async throws -> String?
    /// Imports a file as the Mac imports one of its kind (`book` for an EPUB or a PDF imported as a book);
    /// the source's id when the import knows it.
    func importFile(at file: URL, kind: JobFileKind, title: String?, asBook: Bool) async throws -> String?
    /// Fetches the content of a source a light client added with none yet (a skeletal Source, §5.4).
    func fetchContent(sourceID: String) async throws
    /// Attaches a file a light client uploaded to the skeletal source it made for it.
    func attachFile(at file: URL, kind: JobFileKind, toSource sourceID: String) async throws
    /// Runs an MCP tool through the Mac's own handler, with its checks and its cost confirmation.
    func callTool(_ name: String, arguments: [String: SyncJSON]) async -> (text: String, isError: Bool)
    /// The decoded bytes a FileRef names, from the private `Content` zone.
    func bytes(of file: FileRef) async throws -> Data
    /// One extra run of a scheduled task this Mac runs.
    func runAutomation(_ id: String) async throws
    /// Draws the cover a `makeDerived` Job asks for (D53, §5.9), the creation of a notebook made on a light
    /// client; the Job's note. Throws with the Setting off.
    func drawNotebookCover(notebookID: String) async throws -> String
    /// Tells the open windows the library changed.
    func libraryDidChange() async
    /// Moves a notebook into a space this account owns, or into a new one the Job's `params` describe
    /// (`SpaceMoveJob.runRequest`, §5.3); the space's id. A move resumes where a crash left it.
    func moveIntoSpace(jobID: String, notebookID: String, params: [String: SyncJSON]) async throws -> String
}

extension MacJobWork {
    func moveIntoSpace(jobID: String, notebookID: String, params: [String: SyncJSON]) async throws -> String {
        throw MacJobRunner.Failure(message: "This Mac cannot move a notebook into a space yet.")
    }
}

/// Claims and runs the Jobs light clients write (docs/cloudkit-schema-design.md §3.5.28, §5.4, D47):
/// after each sync round, `pass()` claims what this Mac can run by writing only `claim` (S, so the
/// save the server accepts first wins and a later claimer's merge keeps the winner), starts a Job only
/// once the replica holds its claim as the server acknowledged it, renews its 15-minute lease while it
/// runs, takes over a Job whose lease ran out with a compare-and-set save of `claim`, and marks a Job
/// that a quit interrupted as failed. A Job that names a kind this build cannot run, or a target in a
/// space this Mac does not hold yet, stays queued for a Mac that can; a capture into a space notebook
/// copies the source into the space first (§9.4).
actor MacJobRunner {
    static let lease: TimeInterval = 15 * 60
    static let renewal: TimeInterval = 5 * 60
    /// How much of a tool's answer a Job's `result.note` keeps.
    static let noteLimit = 2_000
    /// The tools a Job may run, by kind: the MCP calls the hosted MCP and the web hand a Mac
    /// (`params = {tool, arguments}`, WP25b and WP23b).
    static let tools: [String: Set<String>] = [
        "generateCourse": ["generate_course"],
        "generateAudio": ["generate_audio_overview"],
        "makeDerived": ["generate_report", "generate_walkthrough"],
        "fetchContent": ["refetch_source_content"],
        "ingestURL": ["import_paper_from_url"],
        "importFeed": ["import_youtube_playlist"],
    ]

    /// Kinds whose work keeps a journal of its own and picks up after a quit instead of failing.
    static let resumable: Set<String> = ["moveToSpace"]

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MacJobRunner")

    private let store: MacPrivateSyncStore.Runner
    private let work: MacJobWork
    private let now: @Sendable () -> Date
    private let scratch: URL
    private var onChange: (@Sendable () async -> Void)?
    /// The Jobs this process is running: one this Mac claimed and finds `running` but not here was
    /// interrupted by a quit.
    private var running: Set<String> = []
    /// Passes never overlap: one that finds another under way asks it to look again when it ends, so a
    /// Job is never started twice nor taken for interrupted while it starts.
    private var passing = false
    private var passAgain = false

    init(store: @escaping MacPrivateSyncStore.Runner, work: MacJobWork, now: @escaping @Sendable () -> Date = { Date() },
         scratch: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ForeverLMJobs", isDirectory: true)) {
        self.store = store
        self.work = work
        self.now = now
        self.scratch = scratch
    }

    /// What to call when the runner wrote something the outbox should send soon (the coordinator's
    /// `sendSoon`).
    func setOnChange(_ handler: @escaping @Sendable () async -> Void) {
        onChange = handler
    }

    /// Runs after each sync round, wired to the coordinator (WP16 builds both). What it writes goes out
    /// a moment later, without holding up the round.
    func attach(to coordinator: SyncCoordinator) async {
        setOnChange { Task { await coordinator.sendSoon() } }
        await coordinator.setAfterRound { [weak self] in _ = await self?.pass() }
    }

    private func read<T>(_ body: @escaping (KnowledgeStore) throws -> T) async throws -> T {
        var result: Result<T, Error>?
        try await store { connection in result = Result { try body(connection) } }
        guard let result else { throw CloudError(.internalError, message: "the store ran nothing") }
        return try result.get()
    }

    // MARK: - A pass

    enum Step: Hashable, Sendable {
        /// The server holds this Mac's claim: start it.
        case start(String)
        /// This Mac's claim, `running`, but not in this process: a quit stopped it.
        case interrupted(String)
        /// Nobody holds it, or the holder's lease ran out: claim it.
        case claim(String)
    }

    /// One pass: what to start, what a quit interrupted, what to claim. Returns the steps it took; the
    /// Jobs it started run on their own.
    @discardableResult
    func pass() async -> [Step] {
        guard !passing else {
            passAgain = true
            return []
        }
        passing = true
        var steps: [Step] = []
        repeat {
            passAgain = false
            steps += await onePass()
        } while passAgain
        passing = false
        return steps
    }

    private func onePass() async -> [Step] {
        let at = now()
        let running = running
        let steps: [Step]
        do {
            steps = try await read { store in try Self.plan(store: store, now: at, running: running) }
            if steps.isEmpty { return [] }
            try await read { store in
                try store.inDerivationTransaction { store in
                    for step in steps { try Self.write(step, store: store, now: at) }
                }
            }
        } catch {
            Self.logger.error("A Job pass failed: \(String(describing: error), privacy: .public)")
            return []
        }
        for case .start(let id) in steps {
            self.running.insert(id)
            Task { await self.run(id) }
        }
        await onChange?()
        return steps
    }

    /// The steps the store calls for now, for this Mac (`ck_clock`'s device). Pure over the store.
    static func plan(store: KnowledgeStore, now: Date, running: Set<String>) throws -> [Step] {
        guard let device = try store.generation2DeviceID() else { return [] }
        let replica = store.replica
        var steps: [Step] = []
        for job in try JobRow.open(connection: store) {
            let held = try replica.record(zoneKey: PrivateSyncZones.libraryKey, recordType: SyncRecordType.job.rawValue, wireID: job.id)
                .flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
            let acknowledged = held?.fields["claim"]?["device"]?.stringValue
            if acknowledged == device {
                guard job.claimDevice == device else { continue }
                // Started here: its lease was written after this Mac's claim. A Job taken over from a Mac
                // whose lease ran out is `running` under that older lease, and starts.
                let startedHere = job.status == "running" && (job.leaseUntil ?? 0) > (job.claimedAt ?? .infinity)
                if !startedHere {
                    steps.append(.start(job.id))
                } else if !running.contains(job.id) {
                    // A move resumes from its own journal (`SpaceMoveJob`), so a quit only pauses it.
                    steps.append(resumable.contains(job.kind) ? .start(job.id) : .interrupted(job.id))
                }
                continue
            }
            // This Mac's claim is on its way: wait for the server's answer.
            if job.claimDevice == device { continue }
            // Another Mac holds a lease that has not run out.
            if acknowledged != nil, let until = job.leaseUntil ?? job.claimedAt.map({ $0 + lease }), until > now.timeIntervalSinceReferenceDate {
                continue
            }
            guard try canRun(job, store: store, device: device) else { continue }
            steps.append(.claim(job.id))
        }
        return steps
    }

    private static func write(_ step: Step, store: KnowledgeStore, now: Date) throws {
        let seconds = now.timeIntervalSinceReferenceDate
        switch step {
        case .claim(let id):
            guard let device = try store.generation2DeviceID() else { return }
            // Only `claim`: the claimer writes nothing else until the server took it (§3.5.28).
            let claim = SyncJSON.object(["device": .string(device), "at": SyncJSON(SyncTime.milliseconds(now))])
            try store.execute("UPDATE jobs SET claim_json = ? WHERE id = ?", [.text(String(decoding: claim.serialized(), as: UTF8.self)), .text(id)])
        case .start(let id):
            try store.execute("UPDATE jobs SET status = 'running', lease_until = ? WHERE id = ?", [.real(seconds + lease), .text(id)])
        case .interrupted(let id):
            try store.execute(
                "UPDATE jobs SET status = 'failed', error = ? WHERE id = ? AND status = 'running'",
                [.text("ForeverLM closed before this job finished."), .text(id)]
            )
        }
    }

    /// Whether this Mac can carry out `job` now. A kind this build does not run, a tool outside its
    /// kind's list, or a filing target not here yet waits for a Mac that can.
    static func canRun(_ job: JobRow, store: KnowledgeStore, device: String) throws -> Bool {
        if let tool = job.params["tool"]?.stringValue {
            return tools[job.kind]?.contains(tool) == true
        }
        switch job.kind {
        case "ingestURL":
            if let source = sourceTarget(job) { return try store.sourceExists(source) }
            guard job.params["url"]?.stringValue?.isEmpty == false else { return false }
            return try filing(job, store: store) != .waits
        case "ingestFile":
            guard let file = job.params["file"].flatMap(FileRef.init(json:)), fileKind(job) != nil else { return false }
            if let source = sourceTarget(job) { return try store.sourceExists(source) }
            guard job.params["sha256"]?.stringValue?.isEmpty == false, file.heldBy == nil else { return false }
            return try filing(job, store: store) != .waits
        case "makeDerived":
            // A cover (D53): this Mac holds the notebook's record, so the cover has something to read, and the
            // notebook has its name: one still under the placeholder waits (a light client queues the Job at
            // creation) until the naming step names it, as the creation queue does.
            guard job.params["derived"]?.stringValue == "cover", let notebook = notebookTarget(job) else { return false }
            guard try NotebookCoverTarget.held(notebook, connection: store) != nil else { return false }
            return try !NotebookCoverNaming.isUnnamed(notebook, connection: store)
        case "runAutomation":
            guard let automation = job.params["automationID"]?.stringValue,
                  let runner = try store.scalarText("SELECT COALESCE(runner_device_id, '') FROM scheduled_tasks WHERE id = ?", [.text(automation)])
            else { return false }
            return runner.isEmpty || runner == device
        case "moveToSpace":
            return try canMove(job, store: store)
        default:
            return false
        }
    }

    /// A move this Mac can run (§5.3): the target is a notebook of the learner's own library here, not a
    /// stub, and the space is one this account owns and this Mac holds with its root, or a new one the Job
    /// describes (`newSpace` `{kind: notebook | team, name}`).
    static func canMove(_ job: JobRow, store: KnowledgeStore) throws -> Bool {
        guard let target = job.target.flatMap(ItemRef.init), target.kind == .notebook,
              try store.scalarInteger("""
                  SELECT EXISTS(SELECT 1 FROM learning_goals WHERE wire_key = ? AND team_id IS NULL
                      AND COALESCE(merged_into, '') = '' AND COALESCE(moved_to, '') = '' AND COALESCE(entity_kind, '') <> 'goal')
              """, [.text(target.id)]) == 1
        else { return false }
        if let spaceID = job.params["spaceID"]?.stringValue, !spaceID.isEmpty {
            let zoneKey = ReplicaZone.key(database: .private, zoneName: SyncSchema.spaceZonePrefix + spaceID)
            return try store.replica.zone(key: zoneKey)?.saltID != nil
        }
        guard let space = job.params["newSpace"]?.objectValue, let kind = space["kind"]?.stringValue else { return false }
        return ["notebook", "team"].contains(kind)
    }

    static func sourceTarget(_ job: JobRow) -> String? {
        job.target.flatMap(ItemRef.init).flatMap { $0.kind == .source ? $0.id : nil }
    }

    static func notebookTarget(_ job: JobRow) -> String? {
        job.target.flatMap(ItemRef.init).flatMap { $0.kind == .notebook ? $0.id : nil }
    }

    static func fileKind(_ job: JobRow) -> JobFileKind? {
        if let kind = job.params["fileKind"]?.stringValue { return JobFileKind(rawValue: kind) }
        // A scan, photos, a PDF, or a share with no kind named: a PDF.
        return .pdf
    }

    // MARK: - Filing (§5.4, §9.4)

    enum Filing: Equatable, Sendable {
        /// No target: the library only.
        case none
        /// The notebook or Goal `resolveNotebook(target)` leads to, with the target's approval.
        case into(goalID: String, approval: String)
        /// A space notebook (§9.4): the space's copy of the source is filed into the notebook's local row.
        case intoSpace(notebookID: String, localID: String, spaceID: String, approval: String)
        /// The target is gone: the source stays in the library.
        case gone(String)
        /// The target's record is here but not projected yet, or its team is not a space yet.
        case waits
    }

    static func filing(_ job: JobRow, store: KnowledgeStore) throws -> Filing {
        guard let target = job.params["target"]?.objectValue else { return .none }
        let approval = target["approval"]?.stringValue ?? "approved"
        if let goal = target["goalID"]?.stringValue {
            return try store.learningGoalRowExists(goal) ? .into(goalID: goal, approval: approval) : .gone(goal)
        }
        guard let notebook = target["notebookID"]?.stringValue else { return .none }
        let resolved = try NotebookResolutionTable.resolve(notebook, connection: store)
        if case .space(let spaceID) = resolved.zone {
            guard let zoneKey = try ReplicaPlacement(connection: store).zoneKey(of: resolved.zone),
                  let local = try SpaceRows.localID(zoneKey: zoneKey, type: .notebook, wireID: resolved.id, connection: store),
                  try store.learningGoalRowExists(local)
            else { return .waits }
            return .intoSpace(notebookID: resolved.id, localID: local, spaceID: spaceID, approval: approval)
        }
        if try store.learningGoalRowExists(resolved.id) {
            // A team's notebook files into the space its team became, once the space has its root.
            guard try store.scalarText("SELECT team_id FROM learning_goals WHERE id = ?", [.text(resolved.id)]) != nil else {
                return .into(goalID: resolved.id, approval: approval)
            }
            guard let zoneKey = try store.scalarText(
                "SELECT zone_key FROM ck_identity WHERE record_type = ? AND local_id = ? ORDER BY zone_key LIMIT 1",
                [.text(SyncRecordType.notebook.rawValue), .text(resolved.id)]
            ), case .space(let spaceID)? = ProjectionZones.zone(ofKey: zoneKey),
                  try store.replica.zone(key: zoneKey)?.saltID != nil
            else { return .waits }
            let wireID = try store.scalarText("SELECT wire_key FROM learning_goals WHERE id = ?", [.text(resolved.id)]) ?? resolved.id
            return .intoSpace(notebookID: wireID, localID: resolved.id, spaceID: spaceID, approval: approval)
        }
        // Its record arrived but waits to be projected: not gone.
        let held = try store.replica.record(zoneKey: PrivateSyncZones.libraryKey, recordType: SyncRecordType.notebook.rawValue, wireID: resolved.id)
        return held == nil ? .gone(notebook) : .waits
    }

    // MARK: - Running one Job

    struct Outcome: Sendable {
        var refs: [String] = []
        var note: String?
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func run(_ id: String) async {
        let renewing = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.renewal * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.renewLease(id)
            }
        }
        var outcome: Result<Outcome, Error>
        do {
            guard let job = try await read({ try JobRow.load(id, connection: $0) }) else { throw Failure(message: "The Job is gone.") }
            outcome = .success(try await carryOut(job))
        } catch {
            outcome = .failure(error)
        }
        renewing.cancel()
        let at = now()
        do {
            try await read { store in
                guard let device = try store.generation2DeviceID(), var job = try JobRow.load(id, connection: store),
                      job.claimDevice == device, job.status == "running" else { return }
                switch outcome {
                case .success(let done):
                    job.status = "done"
                    var result: [String: SyncJSON] = ["refs": .array(done.refs.map(SyncJSON.string))]
                    if let note = done.note { result["note"] = .string(note) }
                    job.result = result
                    job.error = nil
                case .failure(let error):
                    job.status = "failed"
                    job.error = String(error.localizedDescription.prefix(Self.noteLimit))
                }
                job.leaseUntil = at.timeIntervalSinceReferenceDate
                try job.save(store)
            }
        } catch {
            Self.logger.error("A Job's outcome could not be saved: \(String(describing: error), privacy: .public)")
        }
        running.remove(id)
        await work.libraryDidChange()
        await onChange?()
    }

    private func renewLease(_ id: String) async {
        let until = now().addingTimeInterval(Self.lease).timeIntervalSinceReferenceDate
        try? await read { store in
            guard let device = try store.generation2DeviceID() else { return }
            try store.execute(
                "UPDATE jobs SET lease_until = ? WHERE id = ? AND status = 'running' AND json_extract(claim_json, '$.device') = ?",
                [.real(until), .text(id), .text(device)]
            )
        }
        await onChange?()
    }

    /// The Job's work, through the Mac's own paths.
    func carryOut(_ job: JobRow) async throws -> Outcome {
        if let tool = job.params["tool"]?.stringValue {
            let answer = await work.callTool(tool, arguments: job.params["arguments"]?.objectValue ?? [:])
            if answer.isError { throw Failure(message: String(answer.text.prefix(Self.noteLimit))) }
            return Outcome(refs: job.target.map { [$0] } ?? [], note: String(answer.text.prefix(Self.noteLimit)))
        }
        switch job.kind {
        case "ingestURL": return try await ingestURL(job)
        case "ingestFile": return try await ingestFile(job)
        case "makeDerived":
            guard job.params["derived"]?.stringValue == "cover", let notebook = Self.notebookTarget(job) else {
                throw Failure(message: "This Mac draws only a notebook's cover for a makeDerived Job with no tool.")
            }
            return Outcome(refs: [ItemRef(.notebook, notebook).rawValue], note: try await work.drawNotebookCover(notebookID: notebook))
        case "runAutomation":
            guard let automation = job.params["automationID"]?.stringValue else { throw Failure(message: "The Job names no scheduled task.") }
            try await work.runAutomation(automation)
            return Outcome(note: "Run requested.")
        case "moveToSpace":
            guard let target = job.target.flatMap(ItemRef.init), target.kind == .notebook else { throw Failure(message: "The Job names no notebook.") }
            let spaceID = try await work.moveIntoSpace(jobID: job.id, notebookID: target.id, params: job.params)
            return Outcome(refs: [target.rawValue], note: "Moved into space \(spaceID).")
        default:
            throw Failure(message: "This Mac cannot run a \(job.kind) Job.")
        }
    }

    private func ingestURL(_ job: JobRow) async throws -> Outcome {
        if let source = Self.sourceTarget(job) {
            try await work.fetchContent(sourceID: source)
            return Outcome(refs: [ItemRef(.source, source).rawValue])
        }
        guard let url = job.params["url"]?.stringValue else { throw Failure(message: "The Job names no address.") }
        let keys = (job.params["workKeys"]?.arrayValue ?? []).compactMap(\.stringValue)
        // Lookup before mint (§4.2): an active source holding one of the Job's work keys is the source.
        var sourceID = try await read { store in try store.activeSourceID(forWorkKeys: keys) }
        if sourceID == nil {
            let imported = try await work.importLink(url)
            sourceID = try await read { store in try imported ?? store.activeSourceID(forWorkKeys: keys) }
        }
        guard let sourceID else { throw Failure(message: "The page could not be added.") }
        return try await file(sourceID, for: job)
    }

    private func ingestFile(_ job: JobRow) async throws -> Outcome {
        guard let file = job.params["file"].flatMap(FileRef.init(json:)), let kind = Self.fileKind(job) else {
            throw Failure(message: "The Job names no file.")
        }
        let asBook = job.params["collection"]?.stringValue == "book"
        if let source = Self.sourceTarget(job) {
            let local = try await download(file, kind: kind, title: job.params["title"]?.stringValue, job: job.id)
            defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
            try await work.attachFile(at: local, kind: kind, toSource: source)
            return Outcome(refs: [ItemRef(.source, source).rawValue])
        }
        guard let sha = job.params["sha256"]?.stringValue?.lowercased() else { throw Failure(message: "The Job names no file hash.") }
        let key = "file:\(sha)"
        var sourceID = try await read { store in try store.activeSourceID(forWorkKeys: [key]) }
        if sourceID == nil {
            let local = try await download(file, kind: kind, title: job.params["title"]?.stringValue, job: job.id)
            defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
            let imported = try await work.importFile(at: local, kind: kind, title: job.params["title"]?.stringValue, asBook: asBook)
            sourceID = try await read { store in try imported ?? store.activeSourceID(forWorkKeys: [key]) }
            if asBook, sourceID == nil { return Outcome(note: "Imported as a book.") }
            guard let sourceID else { throw Failure(message: "The file could not be added.") }
            // The source's file is the satellite the client uploaded, its FileRef verbatim (D41), so
            // nothing is uploaded again.
            try await read { store in try store.keepJobFileRef(file, role: kind.rawValue, sourceID: sourceID) }
        }
        guard let sourceID else { throw Failure(message: "The file could not be added.") }
        return try await self.file(sourceID, for: job)
    }

    /// The FileRef's bytes in a folder of their own, named by the title so an import that names its
    /// copy after the file names it well.
    private func download(_ file: FileRef, kind: JobFileKind, title: String?, job: String) async throws -> URL {
        let data = try await work.bytes(of: file)
        let folder = scratch.appendingPathComponent(job, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (title ?? "").components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = folder.appendingPathComponent((name.isEmpty ? "Imported" : String(name.prefix(120))) + "." + kind.fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Files the source where the Job says (§5.4): into `resolveNotebook(target)` with the target's
    /// approval; a target that is gone leaves it in the library.
    private func file(_ sourceID: String, for job: JobRow) async throws -> Outcome {
        let source = ItemRef(.source, sourceID).rawValue
        let filing = try await read { store in try Self.filing(job, store: store) }
        switch filing {
        case .none:
            return Outcome(refs: [source])
        case .gone(let target):
            return Outcome(refs: [source], note: "Added to the library: the notebook \(target) is gone.")
        case .waits:
            throw Failure(message: "The notebook is in a space this Mac cannot file into yet.")
        case .intoSpace(let notebook, let local, let space, let approval):
            try await read { store in
                let team = try SpaceRows.localTeamID(spaceID: space, connection: store)
                try store.fileIntoSpaceNotebook(sourceID, notebookID: local, spaceID: space, approval: approval) { path in
                    try SpaceCopyFiles.copy(relativePath: path, teamID: team)
                }
            }
            return Outcome(refs: [source, ItemRef(.notebook, notebook).rawValue])
        case .into(let goal, let approval):
            try await read { store in try store.fileJobSource(sourceID, into: goal, approval: approval) }
            return Outcome(refs: [source, ItemRef(.notebook, goal).rawValue])
        }
    }
}

extension KnowledgeStore {
    func learningGoalRowExists(_ id: String) throws -> Bool {
        try scalarInteger("SELECT EXISTS(SELECT 1 FROM learning_goals WHERE id = ?)", [.text(id)]) == 1
    }

    /// The learner's own active source holding any of `keys` (lookup before mint, §4.2); nil for none,
    /// and for an archived one, which the import brings back.
    func activeSourceID(forWorkKeys keys: [String]) throws -> String? {
        guard let id = try sourceID(forWorkKeys: keys, teamID: nil) else { return nil }
        return try scalarText("SELECT status FROM sources WHERE id = ?", [.text(id)]) == "active" ? id : nil
    }

    /// The source's file of `role` is the satellite a light client uploaded: its FileRef verbatim (D41).
    func keepJobFileRef(_ file: FileRef, role: String, sourceID: String) throws {
        try execute("""
            INSERT INTO source_files (source_id, role, file_ref, local_path) VALUES (?, ?, ?, NULL)
            ON CONFLICT(source_id, role) DO UPDATE SET file_ref = excluded.file_ref
        """, [.text(sourceID), .text(role), .text(String(decoding: file.value.serialized(), as: UTF8.self))])
    }

    /// Files a source a Job brought into a notebook or Goal, through the app's own membership write: an
    /// approved one as the notebook's Add does (`addCompanionSeedSources`, so it arrives ticked, §5.6), a
    /// pending one as a suggestion.
    func fileJobSource(_ sourceID: String, into goalID: String, approval: String) throws {
        if approval == LearningGoalItemReviewState.approved.rawValue {
            _ = try addCompanionSeedSources(goalID: goalID, sourceIDs: [sourceID])
        } else {
            try insertLearningGoalItem(goalID: goalID, sourceID: sourceID, origin: "added", reviewState: approval)
        }
    }
}
