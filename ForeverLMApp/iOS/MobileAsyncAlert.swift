// The alerts the phone raises on its own schedule, and their queue.

import Foundation

/// The alerts the phone raises on its own schedule, and the order in which they
/// are allowed on screen.
///
/// UIKit runs one alert transition at a time. When a second `.alert` flips true
/// while the first is still animating, the running transition resolves a
/// context whose view controller is no longer an alert, and UIKit aborts the
/// process instead of queueing: "A view controller not containing an alert
/// controller was asked for its contained alert controller." That abort is a
/// SIGABRT on the main thread, indistinguishable from a launch crash when it
/// lands during the first load.
///
/// The dialogs a learner opens by hand cannot collide — that would take two
/// taps in one runloop turn. These three can, because each is raised by work
/// finishing rather than by a tap: a text-to-speech that has priced itself, a book
/// that has run out, an offline save that failed. Two of them landing together
/// is ordinary, not exotic — a bulk offline save that fails for several sources
/// raises one per failing row at once.
///
/// So they queue. `resolve` names the single alert allowed on screen; the
/// others keep their state and take their turn as each is dismissed. Every
/// asynchronous alert on iOS must bind its presentation through here — a new
/// one that presents on its own terms reintroduces the crash.
enum MobileAsyncAlert: Equatable {
    /// A text-to-speech waiting for the learner to approve what it will cost.
    case textToSpeechCost
    /// The offer to keep playing through a finished book.
    case bookContinuation
    /// A failed offline save, reported on the row it belongs to.
    case offlineSaveFailure(sourceID: String)

    /// The alert that may present, given everything currently pending.
    ///
    /// Priority runs in declaration order: spending the learner's money is
    /// asked first, and a failure notice — which loses nothing by waiting,
    /// since it stays pending until dismissed — is asked last. Callers pass
    /// only what they can see; an omitted input is simply not pending, which is
    /// safe because nothing outranks an alert that a caller cannot observe.
    static func resolve(
        textToSpeechCostPending: Bool = false,
        bookContinuationPending: Bool = false,
        offlineFailureSourceID: String? = nil
    ) -> MobileAsyncAlert? {
        if textToSpeechCostPending { return .textToSpeechCost }
        if bookContinuationPending { return .bookContinuation }
        if let sourceID = offlineFailureSourceID { return .offlineSaveFailure(sourceID: sourceID) }
        return nil
    }
}
