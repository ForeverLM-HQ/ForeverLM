// The current macOS user.
import SwiftUI
import AppKit

// MARK: - Current macOS user

/// User-owned display identity for account chrome and the idle chat greeting.
/// The Mac account name supplies the first value; the synced preference is the
/// durable authority after the user edits it on any client.
enum MacAccountUser {
    static let displayNamePreferenceKey = Prefs.Account.displayName.name
    /// Synced: whether the account menu shows a complimentary account's
    /// "Usage is paid for" row with its crown, and the web's footer its crown
    /// (the Mac's account button carries none). On unless
    /// the learner hides them, for a screenshot or a recording; Settings ›
    /// AI Usage still says who pays.
    /// The web Studio's name field takes the same length.
    static let maximumDisplayNameLength = 120

    /// Full name from the macOS account, used only to seed the user-owned synced
    /// profile name. A name the user edits on web or another Mac wins thereafter.
    private static let systemFullName: String? = {
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }()

    static var fullName: String? {
        resolvedFullName(saved: Preferences.value(Prefs.Account.displayName))
    }

    /// The name to show for a saved preference value. A view that observes the
    /// key passes the value it read, so a rename redraws it.
    static func resolvedFullName(saved: String?) -> String? {
        // Release/UI-test captures must never inherit the developer's local
        // account name. This is display-only and does not touch synced state.
        if UITestConfiguration.isUITesting { return "Learner" }
        let saved = saved?.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved?.isEmpty == false ? saved : systemFullName
    }

    static func seedSyncedDisplayNameIfNeeded() {
        let saved = Preferences.value(Prefs.Account.displayName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard saved.isEmpty, let systemFullName else { return }
        Preferences.set(systemFullName, for: Prefs.Account.displayName)
    }

    /// The name as it would be saved: trimmed, and nil when there is nothing
    /// to save. A blank field keeps the current name rather than clearing it,
    /// as on the web; a name past the limit is refused, not cut.
    static func normalizedDisplayName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maximumDisplayNameLength else { return nil }
        return name
    }

    /// Renames the learner on every client. Returns false, writing nothing,
    /// for a name `normalizedDisplayName` refuses.
    @discardableResult
    static func setDisplayName(_ raw: String) -> Bool {
        guard let name = normalizedDisplayName(raw) else { return false }
        Preferences.set(name, for: Prefs.Account.displayName)
        return true
    }

    /// The name to *show* for a saved preference value: `resolvedFullName`,
    /// or, while Screen record mode is on, only its first given name. A take
    /// films the account row and the New chat greeting, and the website shows
    /// the learner by first name alone (product owner, 2026-11-22: the clips
    /// carry the learner's own first name, not the made-up "Richard" stand-in of
    /// 2026-10-12). Display only: what is saved, synced and signed with
    /// (`fullName`, CloudKit, Doc sharing) is untouched, and Settings' name
    /// field reads `resolvedFullName`, so editing never saves the short form.
    static func displayedFullName(saved: String?, recording: Bool = ScreenRecordMode.isEffective) -> String? {
        let full = resolvedFullName(saved: saved)
        return recording ? leadingName(of: full) : full
    }

    /// First given name, for casual greetings ("Good morning, Ada"), the same
    /// with Screen record mode on or off.
    static var firstName: String? {
        leadingName(of: displayedFullName(saved: Preferences.value(Prefs.Account.displayName)))
    }

    static func leadingName(of fullName: String?) -> String? {
        fullName?.components(separatedBy: " ").first
    }

    static var initials: String? { monogram(of: fullName) }

    static func monogram(of fullName: String?) -> String? {
        guard let fullName else { return nil }
        let parts = fullName.components(separatedBy: " ").filter { !$0.isEmpty }
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? nil : String(letters).uppercased()
    }
}
