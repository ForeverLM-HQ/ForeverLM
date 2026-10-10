import Foundation

// One turn of a source chat. Lives here (not in MobileSourceChatService.swift)
// because the planner is also compiled into the macOS unit-test bundle, which
// does not build the chat service.
struct MobileSourceChatMessage: Equatable {
    let role: String
    let content: String
}

struct DrivingSourceAnswerRequest: Equatable {
    let sourceTitle: String
    let sourceText: String
    let question: String
    let recentMessages: [MobileSourceChatMessage]
}

struct DrivingSourcePassage: Equatable {
    let index: Int
    let text: String
}

struct DrivingSourceAnswerPrompt {
    let system: String
    let messages: [(role: String, content: String)]
    let passages: [DrivingSourcePassage]
    let contextCharacterCount: Int
}

enum DrivingSourceAnswerPlanner {
    static let maxSourceCharacters = 240_000
    static let maxRecentMessages = 6
    static let maxRecentMessageCharacters = 450
    static let maxSpokenAnswerCharacters = 900
    static let responseTokenBudget = 360

    static func makePrompt(_ request: DrivingSourceAnswerRequest) -> DrivingSourceAnswerPrompt {
        let boundedSource = String(request.sourceText.prefix(maxSourceCharacters))
        let passages = boundedSource.isEmpty ? [] : [DrivingSourcePassage(index: 0, text: boundedSource)]
        let context = boundedSource
        let recentMessages = compactRecentMessages(request.recentMessages)

        let system = """
        You are ForeverLM's hands-free source chat tutor for someone who may be driving.
        Optimize for low-latency spoken answers: answer directly, use short sentences, and avoid long lists.
        Ground every factual claim in the source text. If the source does not answer the question, say what is missing instead of guessing.
        Keep the answer under \(maxSpokenAnswerCharacters) characters unless the user explicitly asks for more detail.
        Ask at most one short follow-up question.
        """

        let user = """
        Source title: \(request.sourceTitle)

        Source text:
        \(context.isEmpty ? "(No usable source text was available.)" : context)

        User question:
        \(request.question)
        """

        return DrivingSourceAnswerPrompt(
            system: system,
            messages: recentMessages + [(role: "user", content: user)],
            passages: passages,
            contextCharacterCount: context.count
        )
    }

    static func spokenAnswer(from rawResponse: String) -> String {
        let withoutToolBlocks = removeToolCallBlocks(from: rawResponse)
        let collapsed = withoutToolBlocks
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#*`")))

        guard collapsed.count > maxSpokenAnswerCharacters else {
            return collapsed
        }

        let sentences = collapsed.split(
            maxSplits: Int.max,
            omittingEmptySubsequences: true,
            whereSeparator: { ".!?".contains($0) }
        )

        var answer = ""
        var cursor = collapsed.startIndex
        for sentence in sentences {
            guard let range = collapsed[cursor...].range(of: sentence) else { continue }
            let end = range.upperBound
            let punctuationEnd = end < collapsed.endIndex ? collapsed.index(after: end) : end
            let candidate = String(collapsed[..<punctuationEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.count <= maxSpokenAnswerCharacters else { break }
            answer = candidate
            cursor = punctuationEnd
        }

        if !answer.isEmpty { return answer }
        return String(collapsed.prefix(maxSpokenAnswerCharacters - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    static func isSiriDialogSized(_ text: String) -> Bool {
        spokenAnswer(from: text).count <= maxSpokenAnswerCharacters
    }

    private static func compactRecentMessages(_ messages: [MobileSourceChatMessage]) -> [(role: String, content: String)] {
        messages.suffix(maxRecentMessages).map { message in
            let clean = message.content
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let content = clean.count <= maxRecentMessageCharacters
                ? clean
                : String(clean.suffix(maxRecentMessageCharacters))
            return (role: message.role, content: content)
        }
    }

    private static func removeToolCallBlocks(from text: String) -> String {
        var remaining = text
        let startTag = "<flm_tool_call>"
        let endTag = "</flm_tool_call>"
        while let start = remaining.range(of: startTag),
              let end = remaining.range(of: endTag, range: start.upperBound..<remaining.endIndex) {
            remaining.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return remaining
    }
}
