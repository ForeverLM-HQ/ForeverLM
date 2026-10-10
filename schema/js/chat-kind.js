// The kind of a chat recorded before generation 2 wrote kinds (docs/cloudkit-schema-design.md §10,
// D50, D19): the twin of Swift's ChatKindClassifier.swift. A voice session, a walkthrough's chat, a
// course quiz's sitting or a scored review among the chats that predate the `kind` column must not
// become a shareable `chat`. One ordered rule set, which the web's and the hosted MCP's chat writers
// call; the caller fills the evidence from what it holds, so this reads no store. Vectors:
// schema/vectors/chat-kind.json.

import { ENUMS, TYPES } from "./schema.generated.js";

/** `Chat.kind`'s values: `review`, `memory`, `quizSitting`, `walkthrough` and `voice` are private. */
export const CHAT_KINDS = ENUMS.ChatKind;

/** `MemoryReviewSession.idPrefix`, and the MCP's daily reviews and their operation sessions. */
export const MEMORY_ID_PREFIXES = ["memory-", "mcp-memory-review-"];
/** `CourseQuizSitting.sessionIDPrefix`. */
export const COURSE_QUIZ_ID_PREFIX = "course-quiz-";
/** `mac-live-`, `ios-live-`, `carplay-live-`: the realtime voice sessions retired in `76d92fe83`. */
export const LIVE_VOICE_ID_MARKER = "-live-";

/**
 * Whether chats of `kind` stay in the member's Library even when filed in a space notebook (D19):
 * every kind the Chat type's space rule does not allow.
 * @param {string} kind
 */
export function isPrivateChatKind(kind) {
  return !(TYPES.Chat.spaceRule?.allowed ?? []).includes(kind);
}

/**
 * The first rule that holds, in this order: a team's snapshot copy is a `transcript`; generation-1
 * kind `memory` or a memory id is `memory`; a course-quiz id is `quizSitting`; `-live-` in the id is
 * `voice`; a chat a walk's progress names, or one holding a walkthrough step line, is `walkthrough`;
 * generation-1 kind `review`, an overall score, card ids or a graded exchange make a `review`; else
 * `chat`. Prefixes and markers match exactly, letter case included.
 * @param {{id: string, kind?: string | null, isTeamSnapshot?: boolean, isNamedByWalkthroughProgress?: boolean,
 *          holdsWalkthroughStep?: boolean, hasOverallScore?: boolean, hasCardIDs?: boolean,
 *          hasGradedExchange?: boolean}} evidence
 *   `id` is `review_sessions.id`; `kind` the generation-1 kind column (absent before schema 89);
 *   `isTeamSnapshot` means `team_id` is set; `isNamedByWalkthroughProgress` that a walk's
 *   `progress_json.chat_session_id` names it; `holdsWalkthroughStep` that an exchange carries a
 *   walkthrough step line; `hasGradedExchange` that an exchange has a score or an idea coverage.
 * @returns {string}
 */
export function chatKind(evidence) {
  const id = evidence.id;
  if (evidence.isTeamSnapshot === true) return "transcript";
  if (evidence.kind === "memory" || MEMORY_ID_PREFIXES.some((prefix) => id.startsWith(prefix))) return "memory";
  if (id.startsWith(COURSE_QUIZ_ID_PREFIX)) return "quizSitting";
  if (id.includes(LIVE_VOICE_ID_MARKER)) return "voice";
  if (evidence.isNamedByWalkthroughProgress === true || evidence.holdsWalkthroughStep === true) return "walkthrough";
  if (evidence.kind === "review" || evidence.hasOverallScore === true || evidence.hasCardIDs === true
    || evidence.hasGradedExchange === true) {
    return "review";
  }
  return "chat";
}
