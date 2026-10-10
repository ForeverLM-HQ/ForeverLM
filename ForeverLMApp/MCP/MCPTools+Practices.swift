import Foundation

// MARK: - list_practices, decide_practice, set_practice
//
// Study practices over MCP (docs/cloudkit-schema-design.md §3.5.25, §8c): what ForeverLM proposes from
// the learner's history, or what the learner or an assistant sets, each with its evidence and the rule
// the card queue, drafting and the tutor read once it is adopted. The rule engine ships dark until it is
// signed off, so for now practices come from these tools. Practices are Practice records, which only a
// Mac on the new iCloud sync keeps; on the old sync these tools say so.

extension MCPDataStore {
    static let practiceRuleKinds: Set<String> = [
        "reviewWindow", "interleave", "retrievalAfterReading", "draftSeeds", "newCardsPerDay", "walkAfterReading",
    ]

    private func practiceStore() throws -> KnowledgeStore {
        let store = try knowledgeStore()
        guard try store.recordsMemoryForGeneration2() else {
            throw MCPError.invalidInput(PracticeError.generation1.errorDescription ?? "Study practices need the new iCloud sync.")
        }
        return store
    }

    private static func foundationValue(_ json: SyncJSON?) -> Any {
        guard let json, !json.isNull else { return NSNull() }
        return (try? JSONSerialization.jsonObject(with: json.serialized(), options: [.fragmentsAllowed])) ?? NSNull()
    }

    private func practiceRow(_ practice: PracticeRecord) -> [String: Any] {
        func iso(_ seconds: Double?) -> Any { seconds.map { appleToISO($0) } ?? NSNull() }
        return [
            "practice_id": practice.id,
            "rule_id": practice.ruleID ?? NSNull(),
            "scope": practice.scope ?? NSNull(),
            "period": practice.period ?? NSNull(),
            "origin": practice.origin,
            "status": practice.status,
            "title": practice.title,
            "why": practice.body ?? NSNull(),
            "evidence": Self.foundationValue(practice.evidence),
            "min_sample_met": practice.minSampleMet.map { $0 as Any } ?? NSNull(),
            "rule": Self.foundationValue(practice.rule),
            "setting_change": Self.foundationValue(practice.settingChange),
            "decided_at": iso(practice.decidedAt),
            "applied_at": iso(practice.appliedAt),
            "valid_until": iso(practice.validUntil),
            "created_at": iso(practice.createdAt),
        ]
    }

    func listPractices(status: String?) throws -> String {
        let status = Self.trimmedOrNil(status)
        if let status, !PracticeRecord.statuses.contains(status) {
            throw MCPError.invalidInput("status is proposed, adopted, dismissed or retired.")
        }
        let practices = try practiceStore().loadPractices(status: status)
        return try jsonString([
            "practices": practices.map(practiceRow),
            "count": practices.count,
            "engine": ["proposes": PracticeEngine.isEnabled, "version": PracticeEngine.engineVersion],
        ])
    }

    func decidePractice(practiceID: String?, decision: String?) async throws -> String {
        guard let id = Self.trimmedOrNil(practiceID) else { throw MCPError.invalidInput("Pass practice_id, as list_practices returns it.") }
        let statuses = ["adopt": "adopted", "dismiss": "dismissed", "retire": "retired"]
        guard let status = Self.trimmedOrNil(decision).flatMap({ statuses[$0] }) else {
            throw MCPError.invalidInput("decision is adopt, dismiss or retire.")
        }
        let store = try practiceStore()
        guard var practice = try store.loadPractice(id: id) else { throw MCPError.notFound(PracticeError.notFound(id).errorDescription ?? id) }
        let now = Date().timeIntervalSinceReferenceDate
        practice.status = status
        practice.decidedAt = now
        var applied: Any = NSNull()
        if status == "adopted", let change = practice.settingChange, let key = change["key"]?.stringValue, let value = change["value"] {
            applied = try await applyPracticeSetting(key: key, value: value)
            practice.appliedAt = now
        }
        try store.savePractice(practice)
        var row = practiceRow(practice)
        row["setting_applied"] = applied
        return try jsonString(row)
    }

    /// A practice's setting change, through the path the setting's own tool takes: the memory review's
    /// settings through `set_memory_review_settings`, any other through `set_app_setting`.
    private func applyPracticeSetting(key: String, value: SyncJSON) async throws -> Any {
        if key == MemoryCardQueue.newPerDayPreferenceKey {
            guard let count = value.intValue else { throw MCPError.invalidInput("The practice's setting change is not a number of new cards.") }
            let result = try await setMemoryReviewSettings(budgetMinutes: nil, prepareDaily: nil, readyByHour: nil, closeDayHour: nil, newCardsPerDay: count)
            return (try? JSONSerialization.jsonObject(with: Data(result.utf8))) ?? result
        }
        let result = try await setAppSetting(settingID: key, value: Self.foundationValue(value))
        return (try? JSONSerialization.jsonObject(with: Data(result.utf8))) ?? result
    }

    func setPractice(
        practiceID: String?,
        title: String?,
        why: String?,
        rule: Any?,
        status: String?,
        scope: String?,
        suggested: Bool
    ) throws -> String {
        let store = try practiceStore()
        let now = Date().timeIntervalSinceReferenceDate
        var practice: PracticeRecord
        if let id = Self.trimmedOrNil(practiceID) {
            guard let held = try store.loadPractice(id: id) else { throw MCPError.notFound(PracticeError.notFound(id).errorDescription ?? id) }
            practice = held
        } else {
            guard let title = Self.trimmedOrNil(title) else { throw MCPError.invalidInput("A new practice needs a title: the practice in one sentence.") }
            practice = PracticeRecord(
                id: UUID().uuidString.lowercased(), ruleID: nil, scope: "all", period: nil, origin: suggested ? "ai" : "user",
                status: "proposed", title: title, body: nil, evidence: nil, minSampleMet: nil, rule: nil, settingChange: nil,
                madeBy: ["at": SyncJSON(SyncTime.milliseconds(cocoaSeconds: now))], decidedAt: nil, appliedAt: nil, validUntil: nil,
                createdAt: now
            )
            if !suggested { practice.status = "adopted"; practice.decidedAt = now }
        }
        if let title = Self.trimmedOrNil(title) { practice.title = title }
        if let why { practice.body = Self.trimmedOrNil(why) }
        if let scope = Self.trimmedOrNil(scope) {
            guard scope == "all" || scope.hasPrefix("nb:") || scope.hasPrefix("crs:") || scope.hasPrefix("type:") else {
                throw MCPError.invalidInput("scope is all, nb:<notebook id>, crs:<course id> or type:<source type>.")
            }
            practice.scope = scope
        }
        if let rule {
            guard let object = rule as? [String: Any], let kind = object["kind"] as? String, Self.practiceRuleKinds.contains(kind),
                  let data = try? JSONSerialization.data(withJSONObject: object), let json = try? SyncJSON(parsing: data)
            else {
                throw MCPError.invalidInput("rule is {kind, params}, kind one of \(Self.practiceRuleKinds.sorted().joined(separator: ", ")).")
            }
            practice.rule = json
        }
        if let status = Self.trimmedOrNil(status) {
            guard PracticeRecord.statuses.contains(status) else { throw MCPError.invalidInput("status is proposed, adopted, dismissed or retired.") }
            if status != practice.status { practice.decidedAt = now }
            practice.status = status
        }
        do {
            try store.savePractice(practice)
        } catch let error as PracticeError {
            throw MCPError.invalidInput(error.errorDescription ?? "The practice was not saved.")
        }
        return try jsonString(practiceRow(practice))
    }
}
