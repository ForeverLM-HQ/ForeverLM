// What to do after setup, and the iCloud storage notices.
import AppKit
import SwiftUI

// MARK: - After setup

/// What to do first, once setup hands over to the app: read something that
/// came in, quiz yourself on it, ask about the library, plan the day. Shown on
/// the Reader's idle page only after the guide is finished (an install that
/// finished setup before this existed never sees it), and each suggestion
/// ticks off once used. It goes away when all four are done or it is closed.
struct GetStartedSuggestions: View {
    enum Suggestion: Int, CaseIterable, Identifiable {
        case read, quiz, ask, plan

        var id: Int { rawValue }
        var bit: Int { 1 << rawValue }

        var icon: String {
            switch self {
            case .read: return "book"
            case .quiz: return "rectangle.stack"
            case .ask: return "bubble.left.and.text.bubble.right"
            case .plan: return "calendar"
            }
        }

        var title: String {
            switch self {
            case .read: return "Read something you saved"
            case .quiz: return "Quiz yourself on it"
            case .ask: return "Ask about your library"
            case .plan: return "Plan your day"
            }
        }
    }

    static let armedKey = "gettingStarted.suggestionsArmed"
    static let allDone = Suggestion.allCases.reduce(0) { $0 | $1.bit }

    static func isShowing(armed: Bool, doneBits: Int) -> Bool {
        armed && doneBits & allDone != allDone
    }

    @Environment(StudioViewModel.self) private var vm
    @SyncedStorage(Self.armedKey) private var isArmed = false
    @SyncedStorage("gettingStarted.suggestionsDone") private var doneBits = 0

    /// The source the first two suggestions are about, newest first.
    var source: StudioArticle?
    var onOpenSource: (String) -> Void

    var body: some View {
        if Self.isShowing(armed: isArmed, doneBits: doneBits) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Get started")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { doneBits = Self.allDone }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                    .help("Hide suggestions")
                    .accessibilityLabel("Hide suggestions")
                }
                ForEach(Suggestion.allCases) { suggestion in
                    row(suggestion)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .transition(.opacity)
        }
    }

    /// A grey glyph and the suggestion's title, one line each (2026-10-06:
    /// the accent glyphs, a green check and a subline under every row went;
    /// the source the first two are about is the row's tooltip).
    private func row(_ suggestion: Suggestion) -> some View {
        let isDone = doneBits & suggestion.bit != 0
        let needsSource = suggestion == .read || suggestion == .quiz
        return Button {
            perform(suggestion)
            withAnimation(.easeInOut(duration: 0.2)) { doneBits |= suggestion.bit }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isDone ? "checkmark.circle" : suggestion.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(suggestion.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .strikethrough(isDone, color: .secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
        .disabled(needsSource && source == nil)
        .help(help(for: suggestion))
    }

    private func help(for suggestion: Suggestion) -> String {
        switch suggestion {
        case .read, .quiz: return source?.title ?? "Nothing has come in yet"
        case .ask, .plan: return suggestion.title
        }
    }

    private func perform(_ suggestion: Suggestion) {
        switch suggestion {
        case .read:
            if let source { onOpenSource(source.id) }
        case .quiz:
            if let source {
                vm.startCompanionReview(goalID: nil, sourceIDs: [source.id], topic: source.title)
            }
        case .ask:
            vm.requestBlankReviewChat()
        case .plan:
            vm.requestPlanDayChat(request: ReviewSlashCommandParser.planDayRequest(nil))
        }
    }
}

// MARK: - iCloud storage

/// What can stop a library syncing, as the setup guide and Settings › iCloud
/// both show it: a Mac not signed in to iCloud, or an iCloud that is full.
/// Every library syncs (`ICloudStorage`), so there is nothing to choose; when
/// sync is fine this shows nothing.
struct ICloudStorageNotices: View {
    @ObservedObject private var status = CloudKitSyncStatusCenter.shared
    @State private var isSignedIn = CloudRuntimeAvailability.isSignedIn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isSignedIn {
                notice(
                    "This Mac is not signed in to iCloud, so your library stays on this Mac for now. Sign in under System Settings › Apple Account and it starts syncing.",
                    icon: "person.crop.circle.badge.exclamationmark",
                    tint: .orange,
                    action: ("Open iCloud Settings", ICloudStorageNotices.openICloudSettings)
                )
            }
            if status.isICloudFull {
                notice(
                    "Your iCloud storage is full, so sync has paused. \(ICloudStorage.fullConsequence) Free up space or upgrade to the \(ICloudStorage.recommendedPlan) plan.",
                    icon: "externaldrive.badge.exclamationmark",
                    tint: .red,
                    action: ("Manage iCloud Storage", ICloudStorageNotices.openICloudSettings)
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Signing in happens in System Settings; see it on the way back.
            isSignedIn = CloudRuntimeAvailability.isSignedIn
        }
    }

    private func notice(
        _ text: String,
        icon: String,
        tint: Color,
        action: (title: String, run: @MainActor () -> Void)
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Button(action.title, action: action.run)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func openICloudSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud",
            "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings",
            "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }
}
