// The sections, pages, flow and steps of Getting Started.
import AppKit
import SwiftUI

/// The rail's three groups. Setup comes first because its storage and AI
/// steps gate what the source steps may do; the workspace steps only show
/// where things are.
enum GettingStartedSection: String, CaseIterable, Identifiable {
    case setup = "Setup"
    case sources = "Sources"
    case assistant = "Your AI"
    case workspace = "Workspace"

    var id: String { rawValue }

    var steps: [GettingStartedStep] {
        GettingStartedStep.onboardingOrder.filter { $0.section == self }
    }
}

/// The pages of Setup's AI step: the key, then the models.
enum AIStepPage {
    case key
    case models
}

/// A page a Setup step opens after its question. Setup reads like a Typeform
/// (product owner, 2026-10-11: "it really focuses on one thing at a time" and
/// "should be crystal clear for the user what to do at each point"): each page
/// asks one thing and has one button that does it, and a choice that needs
/// more leads to a page of its own rather than opening in place.
enum GettingStartedPage: Hashable {
    /// Full Disk Access, once System Settings is open: add the app, relaunch.
    case addToFullDiskAccess
    /// Articles: a read-later app's export, brought over once.
    case readLaterImport
    /// Papers: the place the learner said their papers live.
    case papers(GettingStartedPaperRoute)
    /// More sources: one page for each source picked, in `moreSourceRows` order.
    case moreSource(GettingStartedStep)
    /// Your AI: one page for each app picked, to add ForeverLM to it.
    case connect(AISubscription)
}

/// The answers to "Where do your papers live?", each with its own page.
enum GettingStartedPaperRoute: Hashable {
    case zotero
    case referenceManager
    case pdfs
}

/// How Setup moves forward, kept apart from the view so it can be tested.
enum GettingStartedFlow {
    /// The pick after `current`, or the first pick when there is no current one.
    static func next<T: Equatable>(after current: T?, in picks: [T]) -> T? {
        guard let current else { return picks.first }
        guard let index = picks.firstIndex(of: current) else { return nil }
        let after = picks.index(after: index)
        return after < picks.endIndex ? picks[after] : nil
    }

    /// The footer's one forward button.
    enum Forward: Equatable {
        /// Continue, to the next page or step.
        case next
        /// Finish, on Setup's last page.
        case finish
        /// Skip, on a page that can be left unanswered.
        case skip
        /// A disabled Continue: the page waits for its answer.
        case waiting
    }

    /// One way forward at a time: Continue once the page is answered, Skip
    /// while it is not but may be left, and otherwise a Continue that waits.
    static func forward(canContinue: Bool, canSkip: Bool, isLast: Bool) -> Forward {
        if canContinue { return isLast ? .finish : .next }
        return canSkip ? .skip : .waiting
    }
}

/// Setup's AI step (product owner, 2026-09-25): ForeverLM's AI features run on the
/// learner's own OpenRouter key, billed by OpenRouter at cost, so the step
/// asks for the key, and any account may run it (the app is free; only MCP
/// is paid for), so a new learner needs only the key. An account that can
/// already pay another way (a comp, or balance left from before top-ups were
/// retired) goes on without one.
enum GettingStartedAIPayment {
    static func isReady(hasOwnKey: Bool, canPayWithoutKey: Bool) -> Bool {
        hasOwnKey || canPayWithoutKey
    }
}

enum GettingStartedStep: Int, CaseIterable, Identifiable {
    case podcasts
    case article
    case paper
    case youtube
    case enhancements
    case storage
    case books
    case courses
    case meetings
    /// Retired with the rest of the tour on 2026-09-24, and with the Planner
    /// itself on 2026-09-30; kept for its bit, like the cases after it.
    case planner
    case memory
    case ideas
    case artifacts
    case assistants
    case subscriptions
    case fullDiskAccess
    /// Books, courses, meetings and YouTube on one screen.
    case moreSources

    var id: Int { rawValue }
    var bit: Int { 1 << rawValue }

    /// Ask for AI-balance consent before importing anything that may enqueue
    /// an LLM task. Keep the raw values stable because `bit` is synced already.
    /// Full Disk Access opens Setup, straight after the welcome
    /// (product owner, 2026-09-24): its relaunch is least in the way before
    /// anything else has been answered, and the Podcasts and Reading List
    /// steps later on find something to read.
    ///
    /// The product owner, 2026-09-24: as few screens as possible. Storage says nothing
    /// the welcome's data page cannot, so it moved there; books, courses,
    /// meetings and YouTube share `moreSources`; and the workspace tour is
    /// gone, since the arrival suggestions and each area's own empty state
    /// show where things are. Those cases stay only for their synced bits.
    ///
    /// The product owner, 2026-09-25: the subscription question comes last. Its real
    /// job is connecting ForeverLM to the AI app the learner pays for, and
    /// that connector has something to reach only once podcasts, the Reading
    /// List and papers are in.
    static let onboardingOrder: [GettingStartedStep] = [
        .fullDiskAccess, .enhancements,
        .podcasts, .article, .paper, .moreSources,
        .subscriptions,
    ]

    /// The rows `moreSources` opens, in the order it lists them.
    static let moreSourceRows: [GettingStartedStep] = [.books, .courses, .meetings, .youtube]

    var section: GettingStartedSection {
        switch self {
        case .fullDiskAccess, .storage, .enhancements: return .setup
        case .subscriptions: return .assistant
        case .podcasts, .books, .article, .paper, .courses, .meetings, .youtube, .moreSources: return .sources
        case .planner, .memory, .ideas, .artifacts, .assistants: return .workspace
        }
    }

    /// Workspace steps explain where something lives; nothing has to happen
    /// before Continue.
    var isTour: Bool { section == .workspace }

    var title: String {
        switch self {
        case .podcasts: return "Podcasts"
        case .books: return "Books"
        case .article: return "Articles"
        case .paper: return "Papers"
        case .courses: return "Courses"
        case .meetings: return "Meetings"
        case .youtube: return "YouTube"
        case .enhancements: return "AI"
        case .storage: return "Storage"
        case .planner: return "Planner"
        case .memory: return "Memory"
        case .ideas: return "Ideas"
        case .artifacts: return "Artifacts"
        case .assistants: return "Claude & ChatGPT"
        case .subscriptions: return "Subscriptions"
        case .fullDiskAccess: return "Full Disk Access"
        case .moreSources: return "More sources"
        }
    }

    var icon: String {
        switch self {
        // Every name here must be a real SF Symbol: an unknown one draws
        // nothing, which is how Podcasts once had no icon ("podcasts").
        case .podcasts: return StudioSidebarTab.podcasts.icon
        case .books: return "book.closed"
        case .article: return "globe"
        case .paper: return "doc.text.magnifyingglass"
        case .courses: return "graduationcap"
        case .meetings: return "person.2.wave.2"
        case .youtube: return "play.rectangle.fill"
        case .enhancements: return "sparkles"
        case .storage: return "icloud"
        case .planner: return "calendar.day.timeline.left"
        case .memory: return StudioRailItem.memory.systemImage
        case .ideas: return "lightbulb"
        case .artifacts: return "square.grid.2x2"
        case .assistants: return "point.3.connected.trianglepath.dotted"
        case .subscriptions: return "bubble.left.and.bubble.right"
        case .fullDiskAccess: return "lock.shield"
        case .moreSources: return "square.stack.3d.up"
        }
    }
}

extension Notification.Name {
    /// Posted by the app menu's "Set Up ForeverLM…" item; the active Studio
    /// window reopens the Getting Started guide, also after "Continue later".
    static let showGettingStarted = Notification.Name("showGettingStarted")
}
