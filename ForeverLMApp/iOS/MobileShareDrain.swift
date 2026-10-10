import Foundation

/// What draining the share inbox does with an item whose capture threw. Anything else stops the drain with
/// the item left for the next one.
enum MobileShareDrain {
    enum Answer: Equatable {
        /// It can never become a source (a linked page, an address that is not the web's, a file that is
        /// not a PDF): dropped, with why, so it does not hold up the items behind it.
        case refused(String)
        /// A capture a Mac finishes: the writer committed its Job, which carries the notebook it was shared
        /// into, so the item is done. Left in the inbox it would write another Job at every drain, and stop
        /// every item behind it from being captured.
        case queuedForMac(String)

        var message: String {
            switch self {
            case .refused(let message), .queuedForMac(let message): return message
            }
        }
    }

    static func answer(to error: Error) -> Answer? {
        if let error = error as? MobileCloudMutationError {
            switch error {
            case .linkedPage, .unsupportedCaptureURL, .unsupportedCaptureFile: return .refused(error.localizedDescription)
            default: return nil
            }
        }
        if let error = error as? MobileRecordWriterError, error == .queuedForMac { return .queuedForMac(error.localizedDescription) }
        return nil
    }
}
