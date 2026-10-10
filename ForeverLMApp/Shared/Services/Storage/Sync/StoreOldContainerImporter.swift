import Foundation

/// The importer's side of Settings › iCloud and the removal gate, over late import (WP16b): the facts come
/// from the shared base's watermark and the lists an import pass keeps on this Mac (`MigrationImportState`),
/// the question's answer is stored where the pass that asked reads it (the importer's or the refresh's), and the final pass before "Remove old iCloud
/// data" is one pass of `MigrationLateImport` (docs/cloudkit-schema-design.md §13.6, §13.8).
///
/// `runPass` is what the coordinator builds around its `MigrationLateImport` (WP16 wires it, with the role
/// this Mac has: the seed-claim holder or the maintenance-lease holder is the importer, any other Mac runs
/// the same pass and leaves the base alone). Registered into `MigrationServices.shared.importer`.
struct StoreOldContainerImporter: OldContainerImporting {
    let store: PrivateSyncLocalStore
    let base: any MigrationBaseStore
    let runPass: @Sendable () async throws -> MigrationPassOutcome

    struct Unavailable: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    func facts() async throws -> OldContainerImportFacts {
        let mark = try await base.watermark()
        // The refresh and the deferred catch-up leave their own question and waiting list (WP16b2); Settings and
        // the removal show one of each, whichever pass asked or left them.
        let lists = try await store.perform { state -> (kept: [MigrationLogEntry], notApplied: [MigrationLogEntry], waiting: [String: Date], questions: [(OldContainerImportFacts.Question.Pass, MigrationImportGuardQuestion)]) in
            var questions: [(OldContainerImportFacts.Question.Pass, MigrationImportGuardQuestion)] = []
            if let question = try MigrationImportState.guardQuestion(state.connection, pass: .importPass) { questions.append((.importPass, question)) }
            if let question = try MigrationImportState.guardQuestion(state.connection, pass: .refresh) { questions.append((.refresh, question)) }
            return (try MigrationImportState.kept(state.connection), try MigrationImportState.notApplied(state.connection),
                    try MigrationImportState.allWaitingSince(state.connection), questions)
        }
        var facts = OldContainerImportFacts()
        if let mark {
            func date(_ milliseconds: Int64?) -> Date? { milliseconds.map(SyncTime.date(milliseconds:)) }
            facts.lastOldZoneWriteAt = date(mark.lastOldWriteAt)
            facts.quietSince = date(mark.quietSince)
            facts.finishedAt = date(mark.finishedAt)
            facts.removedAt = date(mark.removedAt)
        }
        facts.waiting = lists.waiting.sorted { $0.key < $1.key }.map {
            OldContainerImportFacts.WaitingRecord(recordName: $0.key, title: nil, since: $0.value)
        }
        facts.keptRemovals = lists.kept.map { Self.item($0) }.map { .init(id: $0.id, what: $0.what, at: $0.at) }
        facts.notApplied = lists.notApplied.map { Self.item($0) }.map { .init(id: $0.id, what: $0.what, at: $0.at) }
        // A question the learner answered waits for the next pass to take the answer; it asks no more.
        if let (pass, question) = lists.questions.first(where: { $0.1.answer == nil }) {
            facts.question = .init(pass: pass, deleting: question.removing, of: question.of)
        }
        return facts
    }

    /// One pass from the shared base, now. A pass that found old-zone writes has imported them (its
    /// patches are queued and, for the importer, the watermark moved); one that cannot run says why.
    func runFinalPass() async throws -> OldContainerFinalPass {
        switch try await runPass() {
        case .imported(let report):
            let writes = report.changed + report.deleted
            return report.sawOldWrite || writes > 0 ? .foundWrites(count: max(writes, 1)) : .quiet
        case .guardTripped, .waitingForQuestion:
            return .asksQuestion
        case .notReady:
            throw Unavailable(reason: "This Mac has not finished fetching your library yet.")
        case .accountChanged:
            throw Unavailable(reason: "Another iCloud account is signed in than the one this library was moved from.")
        case .waitingForAcknowledgement:
            throw Unavailable(reason: "The last import is still being sent to iCloud.")
        }
    }

    /// An old-zone write ends the quiet stretch: `finishedAt` goes and `quietSince` starts at `date`.
    func restartQuietWait(at date: Date) async throws {
        try await advanceWatermark { mark in
            mark.quietSince = SyncTime.milliseconds(date)
            mark.lastOldWriteAt = SyncTime.milliseconds(date)
            mark.finishedAt = nil
        }
    }

    func recordRemoval(at date: Date) async throws {
        try await advanceWatermark { $0.removedAt = SyncTime.milliseconds(date) }
    }

    /// Apply or Keep, stored on the question for the pass that asked (`MigrationImportState.answer`); the
    /// pass reads it, runs with the guard lifted (Apply) or lists the removals as kept (Keep).
    func answer(_ question: OldContainerImportFacts.Question, _ answer: ImportQuestionAnswer) async throws {
        let stored: MigrationImportGuardQuestion.Answer = answer == .apply ? .apply : .keep
        let pass: MigrationPassKind = question.pass == .refresh ? .refresh : .importPass
        try await store.perform { try MigrationImportState.answer(stored, $0.connection, pass: pass) }
    }

    private func advanceWatermark(_ change: (inout MigrationImportWatermark) -> Void) async throws {
        guard var mark = try await base.watermark() else { throw Unavailable(reason: "The root holds no import base yet.") }
        change(&mark)
        guard try await base.advance(MigrationBaseAdvance(entries: [:], watermark: mark)) else {
            throw Unavailable(reason: "The library's root changed meanwhile; try again.")
        }
    }

    private static func item(_ entry: MigrationLogEntry) -> (id: String, what: String, at: Date) {
        let why: String
        switch entry.reason {
        case .deletedInNewWorld: why = "deleted on this library since"
        case .parentDeletedInNewWorld: why = "its parent was deleted on this library"
        case .neverRemoved: why = "an older ForeverLM removed it; ForeverLM keeps this kind of record"
        case .editedInNewWorld: why = "changed on this library since"
        case .notOwned: why = "an older ForeverLM stopped giving it"
        case .keptByAnswer: why = "kept by your answer"
        case .waitedTooLong: why = "waited 30 days for a record that never came"
        case .spaceMissing: why = "its shared space is not on this Mac"
        }
        return ("\(entry.oldRecord)/\(entry.type)/\(entry.id)/\(entry.reason.rawValue)", "\(entry.type) \(entry.id): \(why)", entry.at)
    }
}
