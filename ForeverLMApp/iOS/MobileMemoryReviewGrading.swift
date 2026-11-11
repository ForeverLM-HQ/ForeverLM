import Foundation
import OSLog

/// What grading today's memory review needs beyond its record: the ideas of
/// its sources, their titles, the notebooks holding them (an analogy's
/// partner) and each source's depth. The typed review
/// (`MobileMemoryReviewViewModel`) and the spoken one
/// (`MobileRealtimeMemoryCheck`) grade through this, so an answer is checked,
/// acknowledged and probed by the same rules whichever way it was given, and
/// by the Mac's rules (`MemoryContourGrade.validate`,
/// `MemoryReviewTutoring.gradeAcknowledgement`).
struct MobileMemoryReviewGrading {
    var ideasBySource: [String: [SourceIdea]] = [:]
    var sourceTitles: [String: String] = [:]
    var notebooksBySource: [String: [MemoryUnderstandingProbe.Notebook]] = [:]
    var depthBySource: [String: MemoryReviewDepth] = [:]

    var ideasByID: [String: SourceIdea] {
        var result: [String: SourceIdea] = [:]
        for ideas in ideasBySource.values {
            for idea in ideas { result[idea.id] = idea }
        }
        return result
    }

    /// Loads it for a review; it can wait on a catalog sync.
    static func load(for review: MobileMemoryReviewRecord, catalog: MobileCloudSourceCatalog = .shared) async -> Self {
        var grading = Self()
        do {
            _ = try await catalog.loadSources()
        } catch {
            Logger(subsystem: "com.foreverlm.mobile", category: "MemoryReviewGrading")
                .error("Loading the sources for the review failed: \(error.localizedDescription, privacy: .public)")
        }
        grading.ideasBySource = await catalog.currentSourceIdeas(sourceIDs: review.sourceIDs)
        let sources = await catalog.currentSources(ids: review.sourceIDs)
        grading.sourceTitles = Dictionary(sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        // Which notebooks hold the day's sources, for an analogy's partner.
        let material = Set(review.sourceIDs)
        var holding: [String: [MemoryUnderstandingProbe.Notebook]] = [:]
        for notebook in await catalog.currentNotebooks().sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) {
            for sourceID in Set(notebook.sourceIDs) where material.contains(sourceID) {
                holding[sourceID, default: []].append(MemoryUnderstandingProbe.Notebook(id: notebook.id, title: notebook.title))
            }
        }
        grading.notebooksBySource = holding
        var depths: [String: MemoryReviewDepth] = [:]
        for source in sources {
            let typeDefault = (try? await MobileModelPreferenceStore.shared
                .valueOrDefault(for: Prefs.Families.reviewDepthByType.key(
                    source.sourceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )))
                .flatMap { MemoryReviewDepth(rawValue: $0) }
            depths[source.id] = MemoryReviewDepth.effective(sourceDepth: nil, typeDefault: typeDefault)
        }
        grading.depthBySource = depths
        return grading
    }

    /// Every source and topic the briefing names, by id, topics included.
    static func briefingTitles(_ review: MobileMemoryReviewRecord) -> [String: String] {
        var titles = MemoryReviewTutoring.sourceTitles(inBriefing: review.briefing ?? "")
        for topic in review.topics { titles[topic.id] = topic.title }
        return titles
    }

    /// The Mac's check, on the Mac's rule: a topic grade against the
    /// briefing's topics and the ideas already graded today (which is what
    /// says whether this answer is the topic's opening), a contour grade
    /// against the source's ideas.
    func validate(arguments: [String: Any], review: MobileMemoryReviewRecord) -> Result<MemoryContourGrade, MemoryContourGrade.ValidationError> {
        if review.isByTopic {
            return MemoryContourGrade.validateTopic(
                arguments: arguments,
                topics: review.topics,
                ideasByID: ideasByID,
                gradedIdeaIDs: Set(review.ideaStates.keys)
            )
        }
        return MemoryContourGrade.validate(arguments: arguments, ideasBySource: ideasBySource)
    }

    /// The validator's words, in the grader's own name.
    static func rejection(_ failure: MemoryContourGrade.ValidationError, review: MobileMemoryReviewRecord) -> String {
        review.isByTopic
            ? failure.message.replacingOccurrences(of: "grade_memory_contour", with: "grade_topic_recall")
            : failure.message
    }

    /// What the tutor is told once a grade has been accepted: the topic
    /// grader's words for a topic, the contour grader's for a source. The
    /// opening of a topic is the grade that reaches its ideas first.
    func acknowledgement(for grade: MemoryContourGrade, review: MobileMemoryReviewRecord) -> String {
        if review.isByTopic {
            let topic = review.topics.first { $0.id == grade.sourceID }
            let states = review.ideaStates
            let isOpening = Set(states.keys).isDisjoint(with: Set(topic?.ideaIDs ?? []))
            return MemoryReviewTutoring.topicGradeAcknowledgement(grade: grade, topic: topic, isOpening: isOpening, priorStates: states)
        }
        let depth = depthBySource[grade.sourceID] ?? .standard
        return MemoryReviewTutoring.gradeAcknowledgement(grade: grade, depth: depth)
    }

    /// An understanding probe Go deeper asks.
    struct Probe {
        let kind: MemoryUnderstandingProbe.Kind
        let ideaID: String
        /// The topic it is on; nil in a review planned source by source.
        let topicID: String?
        /// What the tutor is told, beside the learner's words.
        let note: String
    }

    /// The Mac's `understandingProbeNote` on the phone: when Go deeper is
    /// pressed on a topic, or a source, whose ideas all came back, the probe
    /// after the last one asked, on the idea probed least (wanted first). The
    /// phone has no vector index, so an analogy's partner is an idea of
    /// another of today's topics that came back and whose source sits in
    /// another notebook; with none the rotation skips the analogy. Nil while
    /// anything there is missing or partial.
    func understandingProbe(review: MobileMemoryReviewRecord, lastProbeKind: MemoryUnderstandingProbe.Kind?) -> Probe? {
        guard let current = review.currentSourceID else { return nil }
        let ideas = ideasByID
        let topic = review.topics.first { $0.id == current }
        let ideaIDs = (topic?.ideaIDs ?? (ideasBySource[current] ?? []).map(\.id)).filter { ideas[$0] != nil }
        let states = review.ideaStates
        guard MemoryUnderstandingProbe.isRecalled(ideaIDs: ideaIDs, states: states) else { return nil }
        let recalled = ideaIDs.filter { states[$0]?.status == .produced }
        let wanted = Set(recalled.filter { ideas[$0]?.wanted == true })
        guard let target = MemoryUnderstandingProbe.probeTarget(ideaIDs: recalled, wanted: wanted, states: states) else { return nil }
        let last = lastProbeKind ?? MemoryUnderstandingProbe.lastKind(operations: review.exchanges.map(\.operation))
        var kind = MemoryUnderstandingProbe.next(after: last, includesAnalogy: true)
        var partner: MemoryUnderstandingProbe.AnalogyPartner?
        if kind == .analogy {
            var titles = Self.briefingTitles(review)
            for (id, title) in sourceTitles { titles[id] = title }
            partner = topic.flatMap {
                MemoryUnderstandingProbe.analogyPartner(
                    forTopic: $0,
                    among: review.topics,
                    ideasByID: ideas,
                    states: states,
                    notebooksBySource: notebooksBySource,
                    titles: titles
                )
            }
            if partner == nil { kind = MemoryUnderstandingProbe.next(after: last, includesAnalogy: false) }
        }
        return Probe(
            kind: kind,
            ideaID: target,
            topicID: topic?.id,
            note: MemoryUnderstandingProbe.reviewNote(kind: kind, ideaID: target, topicID: topic?.id, partner: partner)
        )
    }

    /// A depth the learner asked for: per source for this review (the Mac
    /// keeps it on the source's row), per kind of source as the account's
    /// preference.
    func applyingDepth(_ depth: MemoryReviewDepth, sourceID: String?, sourceType: String?, review: MobileMemoryReviewRecord) async -> Self {
        var applied = self
        if let sourceID, review.sourceIDs.contains(sourceID) {
            applied.depthBySource[sourceID] = depth
        } else if let sourceType = sourceType?.lowercased(), !sourceType.isEmpty {
            do {
                try await MobileModelPreferenceStore.shared.set(
                    depth.rawValue,
                    for: Prefs.Families.reviewDepthByType.key(
                        sourceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    )
                )
            } catch {
                Logger(subsystem: "com.foreverlm.mobile", category: "MemoryReviewGrading")
                    .error("Saving the review depth for a kind of source failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return applied
    }
}
