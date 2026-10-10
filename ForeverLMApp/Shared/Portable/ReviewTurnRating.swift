#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The learner's thumb on one tutor turn. Stored on the exchange the turn
/// belongs to (`review_exchanges.rating`, schema 93) and carried inside the
/// ReviewSession payload, so a rating made on either Mac reaches the other.
///
/// No surface rates a turn since 2026-09-27, when the thumbs left the chat
/// footer, and nothing reads a rating into a prompt since the question
/// calibration they fed was retired the same day. The stored ratings stay,
/// and sync still decodes and round-trips them: an older build's ratings
/// arrive in the same payload, and blanking them here would erase them there.
enum ReviewTurnRating: String, Codable, Equatable, Sendable {
    case liked
    case disliked
}
