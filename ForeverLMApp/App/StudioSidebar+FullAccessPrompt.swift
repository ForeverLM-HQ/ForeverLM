// The source sidebar's full disk access prompt.
import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension StudioSidebar {
    /// Whether to show a prominent access prompt instead of the source list.
    var showFullAccessPrompt: Bool {
        if sidebar.sidebarTab == .podcasts,
           vm.needsPodcastAccess,
           !vm.podcastAccessPromptDismissed {
            return windowVM.tabTotalCount == 0
        }
        if isBrowserReadingListTab,
           vm.needsBrowserAccess,
           !vm.browserAccessPromptDismissed {
            return windowVM.tabTotalCount == 0
        }
        return false
    }

    var isBrowserReadingListTab: Bool {
        sidebar.sidebarTab == .articles || sidebar.sidebarTab == .papers
    }

    /// Prominent prompt when protected browser or podcast data needs access.
    @ViewBuilder
    var fullAccessPrompt: some View {
        VStack {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.orange.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "lock.shield")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(fullAccessPromptHeading)
                            .font(.headline)
                        Text(fullAccessPromptTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Text(fullAccessPromptMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Label(fullAccessSettingsStep, systemImage: "1.circle.fill")
                    if isDevelopmentBuild {
                        Text(fullAccessBundlePath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 22)
                    }
                    Label(fullAccessRelaunchStep, systemImage: "2.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let detail = fullAccessPromptErrorDetail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        openFullDiskAccessSettings()
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        relaunchApp()
                    } label: {
                        Label("Relaunch \(ForeverLMRuntimeIdentity.displayName)", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)

                    if isDevelopmentBuild {
                        Button {
                            revealAppInFinder()
                        } label: {
                            Label("Reveal App", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .help("Show the running \(ForeverLMRuntimeIdentity.displayName) app in Finder so it can be added to the Full Disk Access list.")
                    }

                    Spacer()

                    Button("Dismiss") {
                        clearFullAccessWarning()
                    }
                    .buttonStyle(.hoverWash)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var fullAccessPromptTitle: String {
        if sidebar.sidebarTab == .podcasts {
            return "Needed for Apple Podcasts"
        }
        if isBrowserReadingListTab {
            return "Needed for reading lists"
        }
        return "Permission required"
    }

    private var fullAccessPromptHeading: String {
        "Full Disk Access"
    }

    private var fullAccessPromptMessage: String {
        if isDevelopmentBuild {
            let source = sidebar.sidebarTab == .podcasts ? "Apple Podcasts" : "browser reading-list data"
            return "DevLM can't read \(source). macOS treats it as a separate signed app from the production ForeverLM copy in Applications, so production access does not cover Dev."
        }

        if sidebar.sidebarTab == .podcasts {
            return "ForeverLM needs Full Disk Access to read your Apple Podcasts database and transcript cache directly."
        }

        let accessWarnings = vm.discoveryWarnings(for: sidebar.sidebarTab).filter { $0.contains("access is blocked") }
        let needsSafari = accessWarnings.contains { $0.contains("Safari") }
        let needsChrome = accessWarnings.contains { $0.contains("Chrome") }
        let needsBrave = accessWarnings.contains { $0.contains("Brave") }
        let features: [String] = {
            var items: [String] = []
            if needsSafari { items.append("Safari") }
            if needsChrome { items.append("Chrome") }
            if needsBrave { items.append("Brave") }
            return items
        }()

        if features.isEmpty {
            return "ForeverLM needs Full Disk Access to read browser reading-list data directly."
        }
        return "ForeverLM needs Full Disk Access to read your \(features.joined(separator: " and ")) reading-list data directly."
    }

    /// macOS never lists an app under Full Disk Access on its own — a blocked
    /// read fails silently instead of prompting — so there is no switch to turn
    /// on until the app is added with the "+" button.
    private var fullAccessSettingsStep: String {
        if isDevelopmentBuild {
            return "Click \"Reveal App\", then add that exact DevLM app in Full Disk Access with the \"+\" button. Leave the production ForeverLM entry enabled too."
        }
        return "Click \"Open Settings\" — it jumps straight to the Full Disk Access pane. ForeverLM is not listed there until you add it with the \"+\" button."
    }

    private var fullAccessRelaunchStep: String {
        if isDevelopmentBuild {
            return "If Settings offers \"Quit & Reopen\", choose \"Later\". Return here and click \"Relaunch \(ForeverLMRuntimeIdentity.displayName)\" so this exact signed build restarts with access."
        }
        return "Click \"Relaunch ForeverLM\" — macOS applies Full Disk Access only when the app starts, so a rescan alone can't pick it up."
    }

    /// The First Run app reads the production steps: it stands in for a new
    /// learner, who has no Dev copy to tell apart from the installed one.
    private var isDevelopmentBuild: Bool {
        ForeverLMRuntimeIdentity.isDevelopment && !ForeverLMRuntimeIdentity.isFirstRun
    }

    /// The exact bundle to add in Full Disk Access. Development builds can live
    /// in Xcode's DerivedData or a repository-local custom build directory.
    private var fullAccessBundlePath: String {
        Bundle.main.bundleURL.path
    }

    private func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// The underlying read error (e.g. the Bookmarks.plist permission failure),
    /// shown as a small footnote instead of inside the main explanation.
    private var fullAccessPromptErrorDetail: String? {
        for warning in vm.discoveryWarnings(for: sidebar.sidebarTab) where warning.contains("access is blocked") {
            if let range = warning.range(of: "Last read error: ") {
                return String(warning[range.upperBound...])
            }
        }
        return nil
    }

    func isFullDiskAccessWarning(_ warning: String) -> Bool {
        warning.contains("access is blocked")
            || warning.contains("Full Disk Access")
            || warning.contains("relaunch ForeverLM")
    }

    private func clearFullAccessWarning() {
        if sidebar.sidebarTab == .podcasts {
            vm.dismissPodcastAccessPrompt()
        } else if isBrowserReadingListTab {
            vm.dismissBrowserAccessPrompt()
        }
    }

    private func relaunchApp() {
        FullDiskAccess.relaunch()
    }

    func openFullDiskAccessSettings() {
        FullDiskAccess.openSettings()
    }
}
