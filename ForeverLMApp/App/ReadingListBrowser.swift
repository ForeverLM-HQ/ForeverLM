// The Reading List browsers and their label.
import AppKit
import SwiftUI

/// The browser Reading Lists used by the first-source workflow. Onboarding and
/// the persistent empty-library guide share this copy so they teach the same
/// import path.
enum ReadingListBrowser: String, CaseIterable, Identifiable, Hashable {
    case safari
    case chrome
    case brave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .brave: return "Brave"
        }
    }

    /// The browser's logo in the asset catalog.
    var logoAssetName: String {
        switch self {
        case .safari: return "SafariIcon"
        case .chrome: return "ChromeIcon"
        case .brave: return "BraveIcon"
        }
    }

    var preference: BrowserPreference {
        switch self {
        case .safari: return .safari
        case .chrome: return .chrome
        case .brave: return .brave
        }
    }

    var saveInstruction: String {
        switch self {
        case .safari: return "Choose Share, then Add to Reading List"
        case .chrome: return "Open Reading List, then choose Add current tab"
        case .brave: return "Open Reading List in the sidebar, then choose Add current tab"
        }
    }

    var shortcut: String? {
        switch self {
        case .safari: return "Shortcut: ⇧⌘D"
        case .chrome, .brave: return nil
        }
    }

    /// The per-Mac switch the Reading List scan reads. Unset means on, which
    /// keeps every install from before setup asked; a fresh setup writes all
    /// three off (`holdUntilChosen`) so nothing is imported until the learner
    /// picks a browser in the Articles or Papers step, or in Settings → Sources.
    var enabledPreference: DeviceKey<Bool?> {
        switch self {
        case .safari: return Prefs.Discovery.readingListSafari
        case .chrome: return Prefs.Discovery.readingListChrome
        case .brave: return Prefs.Discovery.readingListBrave
        }
    }

    var isEnabled: Bool {
        DefaultsEscapeHatch.bool(forKey: enabledPreference.name, default: true)
    }

    func setEnabled(_ enabled: Bool) {
        Preferences.set(enabled, for: enabledPreference)
    }

    static var enabled: Set<ReadingListBrowser> {
        Set(allCases.filter(\.isEnabled))
    }

    /// A toggle for this browser: it saves the choice, keeps the view's set of
    /// enabled browsers in step, and tells the caller the set changed.
    func binding(in enabled: Binding<Set<ReadingListBrowser>>, didChange: @escaping () -> Void) -> Binding<Bool> {
        Binding(
            get: { enabled.wrappedValue.contains(self) },
            set: { isOn in
                setEnabled(isOn)
                if isOn {
                    enabled.wrappedValue.insert(self)
                } else {
                    enabled.wrappedValue.remove(self)
                }
                didChange()
            }
        )
    }

    init?(bundleIdentifier: String?) {
        guard let match = Self.allCases.first(where: {
            $0.preference.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier ?? "") == .orderedSame
        }) else { return nil }
        self = match
    }

    /// The Mac's default browser, when it is one whose Reading List ForeverLM
    /// reads. Setup recommends it: it is where the learner already saves pages.
    static var systemDefault: ReadingListBrowser? {
        guard let web = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: web) else { return nil }
        return ReadingListBrowser(bundleIdentifier: Bundle(url: app)?.bundleIdentifier)
    }

    /// First launch: turn off every browser this Mac has no answer for, so the
    /// setup guide's choice is the only thing that starts an import.
    static func holdUntilChosen(defaults: UserDefaults = .standard) {
        for browser in allCases where defaults.object(forKey: browser.enabledPreference.name) == nil {
            defaults.set(false, forKey: browser.enabledPreference.name)
        }
    }
}

/// A Reading List browser's logo and name, as setup and Settings → Sources
/// label their browser switches.
struct ReadingListBrowserLabel: View {
    let browser: ReadingListBrowser

    var body: some View {
        HStack(spacing: 8) {
            Image(browser.logoAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(browser.title)
        }
    }
}
