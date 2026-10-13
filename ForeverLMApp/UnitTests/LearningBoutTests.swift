import Foundation
import Testing
@testable import ForeverLM

/// The Planner's timer: the clock, the write-up that earns the break, and the
/// merge rules that keep two devices on one bout. See docs/planner-design.md,
/// "A bout on the clock".
@Suite("Learning bouts")
struct LearningBoutTests {

    // MARK: - The break's arithmetic

    @Test("A bout earns a minute of rest for every nine learned, floored at five and capped at twenty")
    func earnedBreakMinutes() {
        // The Planner's default block earns the ten minutes the method asks for.
        #expect(LearningBout.earnedBreakMinutes(forMinutesLearned: 90) == 10)
        #expect(LearningBout.earnedBreakMinutes(forMinutesLearned: 45) == 5)
        #expect(LearningBout.earnedBreakMinutes(forMinutesLearned: 120) == 13)
        #expect(LearningBout.earnedBreakMinutes(forMinutesLearned: 180) == 20)
        // The floor: a quarter hour of learning still earns the minimum rest.
        #expect(LearningBout.earnedBreakMinutes(forMinutesLearned: 15) == 5)
        #expect(LearningBout.earnedBreakMinutes(forMinutesLearned: 0) == 5)
        // The cap holds however long the bout ran.
        #expect(LearningBout.earnedBreakMinutes(forMinutesLearned: 600) == 20)
    }

    @Test("The break is earned from what was actually learned, not from the clock that was set")
    func breakFollowsRealMinutes() {
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var bout = LearningBout(dayPlanID: "2026-09-18", title: "GDF15", plannedMinutes: 120, startedAt: started)
        // Cut short after twenty minutes: twenty minutes' worth of rest, which
        // is the floor, not the two hours' worth the clock was set for.
        bout.endedAt = started.addingTimeInterval(20 * 60)
        #expect(bout.minutesLearned() == 20)
        #expect(bout.earnedBreakMinutes() == 5)
        // Run long: the overrun counts, because it was really learned.
        bout.endedAt = started.addingTimeInterval(150 * 60)
        #expect(bout.minutesLearned() == 150)
        #expect(bout.earnedBreakMinutes() == 17)
    }

    // MARK: - Phase

    @Test("A bout's phase is read from its stamps, in the only order they can be set")
    func phaseFollowsTheStamps() {
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let now = started.addingTimeInterval(30 * 60)
        var bout = LearningBout(dayPlanID: "2026-09-18", title: "GDF15", plannedMinutes: 90, startedAt: started)
        #expect(bout.phase(now: now) == .learning)
        bout.endedAt = now
        #expect(bout.phase(now: now) == .writing)
        bout.learned = "GDF15 signals through GFRAL in the hindbrain."
        bout.writtenAt = now
        bout.breakMinutes = 5
        #expect(bout.phase(now: now) == .earned)
        #expect(bout.canStartBreak)
        bout.breakStartedAt = now
        #expect(bout.phase(now: now) == .resting)
        #expect(!bout.canStartBreak)
        bout.breakEndedAt = now.addingTimeInterval(5 * 60)
        #expect(bout.phase(now: now) == .complete)
    }

    @Test("An earned break that is ended without starting is declined, and finishes the bout")
    func declinedBreakFinishesTheBout() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var bout = LearningBout(dayPlanID: "2026-09-18", title: "GDF15", startedAt: now)
        bout.endedAt = now
        bout.learned = "Enough."
        bout.writtenAt = now
        bout.breakEndedAt = now
        #expect(bout.phase(now: now) == .complete)
        // …and normalizing does not throw the stamp away, because declining is
        // a real answer rather than a nonsense state.
        #expect(bout.normalized(now: now).breakEndedAt != nil)
    }

    @Test("The clock running out does not end a bout; it only says how far over it is")
    func overrunKeepsTheBoutOpen() {
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let bout = LearningBout(dayPlanID: "2026-09-18", title: "GDF15", plannedMinutes: 90, startedAt: started)
        let over = started.addingTimeInterval(115 * 60)
        #expect(bout.phase(now: over) == .learning, "a bout past its clock is still running")
        #expect(bout.isOverrunning(now: over))
        #expect(bout.remainingSeconds(now: over) == -25 * 60)
        #expect(LearningBoutCard.overrunText(bout: bout, now: over) == "25m over")
        #expect(LearningBoutCard.overrunText(bout: bout, now: started.addingTimeInterval(150 * 60)) == "1h over")
        #expect(LearningBoutCard.overrunText(bout: bout, now: started.addingTimeInterval(175 * 60)) == "1h 25m over")
    }

    // MARK: - The start sheet

    @Test("The start sheet takes the minutes typed only when they make a bout")
    func startSheetMinutes() {
        #expect(LearningBoutStartSheet.minutes(from: "25") == 25)
        #expect(LearningBoutStartSheet.minutes(from: " 90 ") == 90)
        #expect(LearningBoutStartSheet.minutes(from: "5") == 5)
        #expect(LearningBoutStartSheet.minutes(from: "480") == 480)
        // Outside what a bout can be, Start stays off rather than starting a
        // clock other than the one typed.
        #expect(LearningBoutStartSheet.minutes(from: "4") == nil)
        #expect(LearningBoutStartSheet.minutes(from: "0") == nil)
        #expect(LearningBoutStartSheet.minutes(from: "481") == nil)
        #expect(LearningBoutStartSheet.minutes(from: "") == nil)
        // Every length offered one click away is one the field takes.
        for preset in LearningBoutStartSheet.presetMinutes {
            #expect(LearningBoutStartSheet.minutes(from: String(preset)) == preset)
        }
    }

    @Test("The start sheet says when the clock will stop, what it earns, and the event it runs on")
    func startSheetWording() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 11, minute: 0)))
        #expect(LearningBoutStartSheet.lengthLine(minutes: 25, now: now, calendar: calendar) == "Ends at 11:25 · earns a 5 min break")
        #expect(LearningBoutStartSheet.lengthLine(minutes: 90, now: now, calendar: calendar) == "Ends at 12:30 · earns a 10 min break")
        #expect(LearningBoutStartSheet.lengthLine(minutes: nil, now: now, calendar: calendar) == "A session runs 5 to 480 minutes")
        #expect(LearningBoutStartSheet.eventLine(title: "Office hours", minutesLeft: 25) == "Office hours · 25m left")
        #expect(LearningBoutStartSheet.eventLine(title: "Office hours", minutesLeft: 90) == "Office hours · 1h 30m left")
        #expect(LearningBoutStartSheet.eventLine(title: "Office hours", minutesLeft: 1) == "Office hours · ending")
    }

    @Test("The live bout is the most recently started one that is still going")
    func liveBoutIsTheLatestUnfinished() {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var finished = LearningBout(id: "a", dayPlanID: "2026-09-18", title: "Morning", startedAt: base)
        finished.endedAt = base.addingTimeInterval(3_600)
        finished.learned = "Something"
        finished.writtenAt = base.addingTimeInterval(3_600)
        finished.breakEndedAt = base.addingTimeInterval(3_700)
        let running = LearningBout(id: "b", dayPlanID: "2026-09-18", title: "Afternoon", startedAt: base.addingTimeInterval(7_200))
        #expect(LearningBout.live(in: [finished, running])?.id == "b")
        #expect(LearningBout.live(in: [finished])?.id == nil)
        var abandoned = running
        abandoned.abandonedAt = base.addingTimeInterval(8_000)
        #expect(LearningBout.live(in: [finished, abandoned]) == nil)
    }

    // MARK: - Storage

    @Test("The write-up earns the break and marks the bout's block done; nothing else does")
    func writeUpEarnsTheBreakAndClosesTheBlock() throws {
        let root = temporaryRoot("BoutWriteUp")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let today = DayPlan.dateString(for: Date())

        let block = try store.addTimeBlock(TimeBlock(
            dayPlanID: today, startMinute: 540, endMinute: 630, title: "GDF15", notebookID: "notebook-mito", sourceIDs: ["src-a"]
        ))
        let bout = try store.startLearningBout(LearningBout(dayPlanID: today, blockID: block.id, title: ""))
        // The block's title, Notebook and sources came along.
        #expect(bout.title == "GDF15")
        #expect(bout.notebookID == "notebook-mito")
        #expect(bout.sourceIDs == ["src-a"])
        #expect(try store.loadTimeBlock(block.id)?.status == .planned, "starting a bout completes nothing")

        // No write-up, no break — from any caller.
        #expect(throws: (any Error).self) { try store.startLearningBoutBreak(bout.id) }
        // And the write-up has to say what was learned.
        #expect(throws: (any Error).self) { try store.writeUpLearningBout(bout.id, learned: "   ", unclear: "lots") }

        let written = try store.writeUpLearningBout(
            bout.id,
            learned: "GDF15 acts on GFRAL in the area postrema.",
            unclear: "Why the effect survives vagotomy."
        )
        #expect(written.phase() == .earned)
        #expect(written.canStartBreak)
        #expect(written.breakMinutes >= LearningBout.minimumBreakMinutes)
        #expect(written.endedAt != nil, "writing up stops a running clock")
        #expect(try store.loadTimeBlock(block.id)?.status == .done, "the write-up is the learner saying the work happened")

        let resting = try store.startLearningBoutBreak(bout.id)
        #expect(resting.phase() == .resting)
        #expect(resting.breakEndsAt != nil)
        let done = try store.endLearningBoutBreak(bout.id)
        #expect(done.phase() == .complete)
        #expect(try store.loadLiveLearningBout() == nil)
    }

    @Test("A second bout is refused while one is live")
    func oneBoutAtATime() throws {
        let root = temporaryRoot("BoutSingleton")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let today = DayPlan.dateString(for: Date())

        let first = try store.startLearningBout(LearningBout(dayPlanID: today, title: "GDF15"))
        #expect(throws: (any Error).self) {
            try store.startLearningBout(LearningBout(dayPlanID: today, title: "Something else"))
        }
        // Letting the first one go frees the clock, and earns nothing.
        let abandoned = try store.abandonLearningBout(first.id)
        #expect(abandoned.phase() == .abandoned)
        #expect(!abandoned.canStartBreak)
        let second = try store.startLearningBout(LearningBout(dayPlanID: today, title: "Something else"))
        #expect(try store.loadLiveLearningBout()?.id == second.id)
    }

    @Test("A bout keeps its block through a move, and its write-up through a redraw that replaced the block")
    func boutSurvivesARedraw() throws {
        let root = temporaryRoot("BoutRedraw")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let today = DayPlan.dateString(for: Date())

        let block = try store.addTimeBlock(TimeBlock(dayPlanID: today, startMinute: 540, endMinute: 630, title: "GDF15"))
        let bout = try store.startLearningBout(LearningBout(dayPlanID: today, blockID: block.id, title: "GDF15"))
        var moved = block
        moved.startMinute = 600
        moved.endMinute = 690
        #expect(try store.updateTimeBlock(moved).id == block.id, "a move lands on the block's own row")
        _ = try store.reviseDayPlan(today, replacing: [block.id], replacements: [
            TimeBlock(dayPlanID: today, startMinute: 700, endMinute: 790, title: "GDF15, again"),
        ])

        let written = try store.writeUpLearningBout(bout.id, learned: "It still reads.", unclear: nil)
        #expect(written.blockID == block.id, "the bout keeps the row it was started on")
        // The replaced row is not resurrected or completed by the write-up;
        // the block_id carries no foreign key, so nothing broke either.
        #expect(try store.loadTimeBlock(block.id)?.isCurrent == false)
        #expect(try store.loadLearningBout(bout.id)?.learned == "It still reads.")
    }

    // MARK: - Sync

    @Test("Bouts round-trip through the day's record with every field")
    func cloudKitRoundTrip() throws {
        let senderRoot = temporaryRoot("BoutSender")
        let receiverRoot = temporaryRoot("BoutReceiver")
        defer {
            try? FileManager.default.removeItem(at: senderRoot)
            try? FileManager.default.removeItem(at: receiverRoot)
        }
        let sender = try KnowledgeStore(storeDirectory: senderRoot)
        let receiver = try KnowledgeStore(storeDirectory: receiverRoot)
        let today = DayPlan.dateString(for: Date())

        let block = try sender.addTimeBlock(TimeBlock(dayPlanID: today, startMinute: 540, endMinute: 630, title: "GDF15"))
        let bout = try sender.startLearningBout(LearningBout(
            dayPlanID: today, blockID: block.id, title: "GDF15",
            notebookID: "notebook-mito", sourceIDs: ["src-a", "src-b"], plannedMinutes: 90
        ))
        try sender.writeUpLearningBout(bout.id, learned: "GFRAL is the receptor.", unclear: "The vagotomy result.")
        try sender.startLearningBoutBreak(bout.id, minutes: 12)

        let payload = try #require(try sender.loadDayPlanForSync(today))
        let decoded = try JSONDecoder().decode(CloudKitDayPlanPayload.self, from: try JSONEncoder().encode(payload))
        try receiver.saveDayPlanRecord(decoded)

        let landed = try #require(try receiver.loadLearningBout(bout.id))
        #expect(landed.title == "GDF15")
        #expect(landed.blockID == block.id)
        #expect(landed.notebookID == "notebook-mito")
        #expect(landed.sourceIDs == ["src-a", "src-b"])
        #expect(landed.plannedMinutes == 90)
        #expect(landed.learned == "GFRAL is the receptor.")
        #expect(landed.unclear == "The vagotomy result.")
        #expect(landed.writtenAt != nil)
        #expect(landed.breakMinutes == 12)
        #expect(landed.phase() == .resting)
        // And it reads back through the day the way the panes ask for it.
        #expect(try receiver.loadDayPlan(today)?.bouts.map(\.id) == [bout.id])
    }

    @Test("A record written before bouts existed lands as a day with none")
    func olderRecordDecodes() throws {
        let older = try JSONDecoder().decode(CloudKitDayPlanPayload.self, from: Data("""
        {"plan": {"id": "2026-09-18", "date": "2026-09-18", "revision": 1}, "blocks": []}
        """.utf8))
        #expect(older.bouts.isEmpty)
    }

    @Test("A stale record cannot un-end a bout, and a device that only ended the break cannot blank the write-up")
    func mergeKeepsWhatHappened() {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var written = LearningBout(id: "b1", dayPlanID: "2026-09-18", title: "GDF15", startedAt: base)
        written.endedAt = base.addingTimeInterval(3_600)
        written.learned = "GFRAL is the receptor."
        written.unclear = "The vagotomy result."
        written.writtenAt = base.addingTimeInterval(3_600)
        written.breakMinutes = 10
        written.updatedAt = base.addingTimeInterval(3_600)

        // The phone only ever saw the bout running, and ends its break later.
        var phone = LearningBout(id: "b1", dayPlanID: "2026-09-18", title: "GDF15", startedAt: base)
        phone.breakEndedAt = base.addingTimeInterval(4_200)
        phone.updatedAt = base.addingTimeInterval(4_200)

        let merged = LearningBout.merged(local: written, remote: phone)
        #expect(merged.learned == "GFRAL is the receptor.", "a copy that never saw the write-up must not blank it")
        #expect(merged.unclear == "The vagotomy result.")
        #expect(merged.writtenAt == written.writtenAt, "the stamp is kept once either side has it")
        #expect(merged.endedAt == written.endedAt)
        #expect(merged.breakEndedAt == phone.breakEndedAt)
        #expect(merged.phase(now: base.addingTimeInterval(5_000)) == .complete)

        // The same merge either way round.
        let flipped = LearningBout.merged(local: phone, remote: written)
        #expect(flipped.learned == merged.learned)
        #expect(flipped.writtenAt == merged.writtenAt)
        #expect(flipped.breakEndedAt == merged.breakEndedAt)
    }

    @Test("The earlier of two stamps wins, so the first Mac to end a bout is the one that ended it")
    func mergeKeepsTheEarlierStamp() {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var early = LearningBout(id: "b1", dayPlanID: "2026-09-18", title: "GDF15", startedAt: base)
        early.endedAt = base.addingTimeInterval(1_800)
        early.updatedAt = base.addingTimeInterval(1_800)
        var late = LearningBout(id: "b1", dayPlanID: "2026-09-18", title: "GDF15", startedAt: base)
        late.endedAt = base.addingTimeInterval(3_600)
        late.updatedAt = base.addingTimeInterval(3_600)
        #expect(LearningBout.merged(local: early, remote: late).endedAt == early.endedAt)
        #expect(LearningBout.merged(local: late, remote: early).endedAt == early.endedAt)
    }

    @Test("Deleting a day takes its bouts with it")
    func deletingADayRemovesItsBouts() throws {
        let root = temporaryRoot("BoutDelete")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let today = DayPlan.dateString(for: Date())

        let bout = try store.startLearningBout(LearningBout(dayPlanID: today, title: "GDF15"))
        try store.deleteDayPlan(today)
        #expect(try store.loadLearningBout(bout.id) == nil)
        #expect(try store.loadLiveLearningBout() == nil)
    }

    private func temporaryRoot(_ name: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
