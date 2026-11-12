import Foundation

/// A model is put to work only after it has done that work once, with the
/// parameters that work sends (product owner, 2026-09-26). The directory's own
/// claims are not enough: OpenRouter listed
/// `thinkingmachines/inkling-small:free` as a free model with tools while
/// refusing it outside "agentic harnesses", and GLM 5.3 Flash as a reasoning
/// model while refusing the reasoning opt-out background work sends. Both
/// reached learners' settings and failed every task that used them.
///
/// OpenRouter adds models faster than any sweep could test them, so nothing
/// tests the catalogue ahead of time. A model is tested the first time it is
/// selected for a kind of work, on the spot, and becomes the selection only
/// if it passes. A failure never takes a model out of the pickers (product owner,
/// 2026-09-27): choosing it again tests it again, since one bad run says
/// little. After launch the models the settings already use are asked again
/// when due.
///
/// Each test is one small request through the same path that role's work
/// takes, and the verdict is kept on this device. Only a refusal that is
/// about the model counts as a failure; a rate limit, an outage, an empty
/// balance or an account setting leaves the model untested, to be asked
/// again next time.
///
/// Text-to-speech models are tested the same way (product owner, 2026-10-03:
/// "make sure that before those models can be invoked; there is a test that
/// they can actually be run"), with one short synthesis through the client
/// playback uses: `MacArticleTTSClient` on the Mac, `CloudArticleTTS` on the
/// iPhone and iPad. Free speech models are often busy for a moment ("for
/// free models there might be intermittent unavailability"), so a test of one
/// that cannot finish does not hold the pick back; it is tested again when
/// next used.
///
/// This file is the half both apps compile: the records, the test itself
/// with what it reads passed in, and the text-to-speech rules. The Mac's
/// probes, its sweep and its pickers' wording are in
/// `App/AIModelQualification.swift`; the phone's speech probe is
/// `CloudArticleTTS+Qualification.swift`.
enum AIModelQualification {
    /// The request shapes the app sends, collapsed to the four the pickers
    /// choose for.
    enum Role: String, CaseIterable, Codable, Sendable {
        /// Streaming with the tutor's tools: the chat, and the streaming tasks.
        case chat
        /// A one-shot at temperature 0 in JSON mode with reasoning turned as
        /// far down as the model allows: the strictest background request.
        case background
        /// The same with an image attached.
        case backgroundImages = "background_images"
        /// One short synthesis in the chosen voice (`speechSlug`).
        case speech

        var label: String {
            switch self {
            case .chat: "chat"
            case .background: "background work"
            case .backgroundImages: "multimodal background work"
            case .speech: "text to speech"
            }
        }
    }

    enum Status: Equatable, Sendable {
        case passed
        case failed(String)
        case untested
    }

    struct Record: Codable, Equatable, Sendable {
        var passed: Bool
        var message: String?
        var testedAt: Date
    }

    /// A pass is asked again after a month, so a model OpenRouter later
    /// restricts drops out; a failure after a day, so one that recovers comes
    /// back.
    static let passLifetime: TimeInterval = 30 * MemoryTutorScheduler.secondsPerDay
    static let failureLifetime: TimeInterval = MemoryTutorScheduler.secondsPerDay
    static let taskLabel = "model_qualification"

    /// One in-memory copy of the table per defaults object (the standard one in
    /// the app, a suite of its own in a test), so no defaults call is made
    /// while a lock is held: the copy changes under the memo's lock and the
    /// stored table is written after it is released.
    nonisolated(unsafe) private static let memos = NSMapTable<UserDefaults, PreferenceMemo<Data?>>.weakToStrongObjects()
    private static let memosLock = AppLock()

    private static func memo(for defaults: UserDefaults) -> PreferenceMemo<Data?> {
        memosLock.withLock {
            if let memo = memos.object(forKey: defaults) { return memo }
            let memo = PreferenceMemo(Prefs.Models.qualification)
            memos.setObject(memo, forKey: defaults)
            return memo
        }
    }

    // MARK: Store

    static func key(slug: String, role: Role) -> String {
        "\(normalized(slug))|\(role.rawValue)"
    }

    static func normalized(_ slug: String) -> String {
        slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func decoded(_ data: Data?) -> [String: Record] {
        data.flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }

    private static func table(_ defaults: UserDefaults) -> [String: Record] {
        Preferences.withStorage(defaults) { decoded(memo(for: defaults).value) }
    }

    static func record(slug: String, role: Role, defaults: UserDefaults = .standard) -> Record? {
        table(defaults)[key(slug: slug, role: role)]
    }

    static func status(slug: String, role: Role, defaults: UserDefaults = .standard) -> Status {
        guard let record = Self.record(slug: slug, role: role, defaults: defaults) else { return .untested }
        return record.passed ? .passed : .failed(record.message ?? "It failed its test.")
    }

    static func isPassed(slug: String, role: Role, defaults: UserDefaults = .standard) -> Bool {
        status(slug: slug, role: role, defaults: defaults) == .passed
    }

    /// Whether the model failed its last test for this role: what keeps it
    /// out of automatic picks and backup chains, never out of the pickers.
    static func isKnownToFail(slug: String, role: Role, defaults: UserDefaults = .standard) -> Bool {
        if case .failed = status(slug: slug, role: role, defaults: defaults) { return true }
        return false
    }

    /// Whether the next sweep should test this model for this role.
    static func needsTest(slug: String, role: Role, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard let record = Self.record(slug: slug, role: role, defaults: defaults) else { return true }
        let lifetime = record.passed ? passLifetime : failureLifetime
        return now.timeIntervalSince(record.testedAt) > lifetime
    }

    static func store(_ record: Record, slug: String, role: Role, defaults: UserDefaults = .standard) {
        Preferences.withStorage(defaults) {
            _ = memo(for: defaults).update { stored in
                var current = decoded(stored)
                current[key(slug: slug, role: role)] = record
                if let data = try? JSONEncoder().encode(current) {
                    stored = data
                }
            }
        }
    }

    // MARK: Test

    /// The test itself, with what it reads passed in.
    static func qualify(
        slug: String,
        role: Role,
        force: Bool,
        canTest: Bool,
        defaults: UserDefaults = .standard,
        verdict: (Error) -> String?,
        probe: () async throws -> Void
    ) async -> Status {
        guard force || needsTest(slug: slug, role: role, defaults: defaults) else {
            return status(slug: slug, role: role, defaults: defaults)
        }
        guard canTest else { return status(slug: slug, role: role, defaults: defaults) }
        let gateKey = key(slug: slug, role: role)
        guard await AIModelQualificationGate.shared.begin(gateKey) else {
            return status(slug: slug, role: role, defaults: defaults)
        }
        do {
            try await probe()
            store(Record(passed: true, message: nil, testedAt: Date()), slug: slug, role: role, defaults: defaults)
        } catch {
            if let message = verdict(error) {
                store(Record(passed: false, message: message, testedAt: Date()), slug: slug, role: role, defaults: defaults)
            }
        }
        // Released before the verdict is read, so a pick chosen again at
        // once is tested again rather than answered from the gate.
        await AIModelQualificationGate.shared.end(gateKey)
        return status(slug: slug, role: role, defaults: defaults)
    }

    /// What a picker does with a model the learner just chose.
    enum SelectionVerdict: Equatable, Sendable {
        /// Apply the pick: it passed, or this device cannot test (no key, no
        /// balance), in which case no work runs on it until it can.
        case go
        /// It failed; the message is OpenRouter's.
        case refused(String)
        /// The test could not finish (busy, offline); nothing is applied.
        case retryLater
    }

    // MARK: Text to speech

    /// What a text-to-speech verdict is kept under: the model with the voice
    /// it was tested in. OpenRouter refuses a voice on its own (one its list
    /// dropped, a Fish Audio reference id it does not know) with the same
    /// 400 it gives a format the model does not take, and the answer does not
    /// reliably say which, so a pass in one voice says nothing about another.
    /// A model with no voice list is kept under its slug.
    static func speechSlug(model: String, voice: String) -> String {
        let voice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized(voice.isEmpty ? model : "\(model)#\(voice)")
    }

    /// The voice a request for this model sends: the one asked for when the
    /// model lists it, else its first; empty for a model with no voice list,
    /// whose request names none, as the client resolves it.
    static func resolvedSpeechVoice(model: String, voice: String) -> String {
        ArticleSpeechCatalog.resolvedVoiceID(voice, forModel: model) ?? ""
    }

    static func speechStatus(model: String, voice: String, defaults: UserDefaults = .standard) -> Status {
        status(slug: speechSlug(model: model, voice: resolvedSpeechVoice(model: model, voice: voice)), role: .speech, defaults: defaults)
    }

    /// Whether the pair failed its last test: what a repair of a vanished
    /// pick skips, never what a picker hides.
    static func isSpeechKnownToFail(model: String, voice: String, defaults: UserDefaults = .standard) -> Bool {
        if case .failed = speechStatus(model: model, voice: voice, defaults: defaults) { return true }
        return false
    }

    /// A status that refuses what the request names rather than the moment
    /// or the account: the model (404 or 410 once OpenRouter stops serving
    /// it), or its voice or response format (400, 422). Both speech clients
    /// read it.
    static func isSpeechModelRefusal(statusCode: Int) -> Bool {
        [400, 404, 410, 422].contains(statusCode)
    }

    /// The test a text-to-speech pick runs before it is applied, with what it
    /// reads passed in: `verdict` is the client's reading of a failed
    /// synthesis. A pair that failed before is tested again rather than
    /// refused on its old verdict.
    static func speechSelectionVerdict(
        slug: String,
        isFree: Bool,
        canTest: Bool,
        defaults: UserDefaults = .standard,
        verdict: (Error) -> String?,
        probe: () async throws -> Void
    ) async -> SelectionVerdict {
        let retest = isKnownToFail(slug: slug, role: .speech, defaults: defaults)
        switch await qualify(
            slug: slug,
            role: .speech,
            force: retest,
            canTest: canTest,
            defaults: defaults,
            verdict: verdict,
            probe: probe
        ) {
        case .passed:
            return .go
        case .failed(let message):
            return .refused(message)
        case .untested:
            return untestedSpeechVerdict(canTest: canTest, isFree: isFree)
        }
    }

    /// A text-to-speech test that could not finish: on a device that cannot
    /// test, the pick goes as any other; a free model goes too, and is
    /// tested again when next used; a priced one waits for a test that
    /// finishes.
    static func untestedSpeechVerdict(canTest: Bool, isFree: Bool) -> SelectionVerdict {
        guard canTest else { return .go }
        return isFree ? .go : .retryLater
    }

    /// The one line the text-to-speech settings show in place when a pick
    /// was not applied; `name` names the model and voice.
    static func speechRefusalText(name: String, verdict: SelectionVerdict) -> String? {
        switch verdict {
        case .go:
            return nil
        case .refused(let message):
            return "\(name) failed a test run, so it was not selected. OpenRouter said: \(message)"
        case .retryLater:
            return "\(name) could not be tested just now. Try again in a moment."
        }
    }
}

/// One test per model and role at a time, however many sweeps overlap.
actor AIModelQualificationGate {
    static let shared = AIModelQualificationGate()
    private var running: Set<String> = []

    func begin(_ key: String) -> Bool {
        running.insert(key).inserted
    }

    func end(_ key: String) {
        running.remove(key)
    }
}
