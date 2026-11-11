import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// The learner: their name, what they said about themselves, their word on sharing.
    enum Account {
        /// User-owned profile chrome. The web app cannot reliably recover the
        /// Apple Account name because CloudKit withholds name components when
        /// discoverability is unavailable, so the native app seeds this once and
        /// every client thereafter uses the synced value.
        static let displayName = AccountKey<String>("account.displayName", default: "")
        /// Whether the complimentary-account crown shows (the web's footer, the
        /// Mac account menu's row); the learner hides it once, for every
        /// client's screenshots.
        static let showsCompCrown = AccountKey<Bool>("account.showsCompCrown", default: true)
        /// The learner's own words about where they are coming from
        /// (`LearnerProfile.aboutYouPreferenceKey`): every course tailors its
        /// readings and quizzes to it, on whichever Mac they study.
        static let aboutYou = AccountKey<String?>("account.aboutYou")
        /// The learner's word that they may share the sources they share
        /// (`SharingRightsAffirmation`, its version and when): asked once,
        /// before the first share, and once means on every device, so the
        /// iPhone and the web read and write the same row.
        static let sharingRightsAffirmation = AccountKey<String?>("sharing.rightsAffirmation", .phoneWritable)

        static let all: [AnyPreferenceKey] = [
            displayName.erased,
            showsCompCrown.erased,
            aboutYou.erased,
            sharingRightsAffirmation.erased,
        ]
    }
}
