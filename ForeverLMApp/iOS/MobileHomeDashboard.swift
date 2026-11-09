import SwiftUI

/// Home, a voice interface (product owner, 2026-11-09, after a day of trimming
/// it: "the main use cases for me are voice mode, gym mode …; doing memory review
/// either via voice mode or via tapping the flashcards", "voice and drive and gym
/// … are really all the same", "this is way too much text", "can it just be
/// mostly a voice interface? And then the other things … tucked away in the app,
/// just on an as needed basis").
///
/// One large voice button in the middle (talk, or type when you can't: the voice
/// screen has the field); today's cards as one quiet pill under it, which opens
/// the card review with its pictures; and one menu at the foot holding the rest:
/// notebooks, the library, To Read, Follow Up, the Space, Memory and Settings.
/// Voice itself opens a source the learner names and goes through today's cards
/// when asked, so neither needs a button of its own.
///
/// It draws only what it is handed, so Home (`MobileNotebookHomeView`) and the
/// DEBUG harness (`MobileHomeHarness`) draw the same screen.
struct MobileHomeDashboard<Top: View>: View {
    /// Today's cards; nil until the phone knows (nothing synced yet).
    let cards: MemoryCardDayCounts?
    /// Whether the menu offers the Space (it opens on generation 2).
    let showsSpaces: Bool
    let actions: MobileHomeActions
    /// What sits above the voice button while it matters: a running bout.
    @ViewBuilder let top: () -> Top

    var body: some View {
        VStack(spacing: 0) {
            top()
                .padding(.horizontal, MobileHomeMetrics.margin)
                .padding(.top, MobileDesign.Spacing.small)
            Spacer(minLength: MobileDesign.Spacing.xLarge)
            MobileHomeVoiceButton(talk: actions.talk)
            if let cards, cards.today > 0 {
                MobileHomeCardsPill(count: cards.today) { actions.open(.cardReview(.allNotebooks)) }
                    .padding(.top, 40)
            }
            Spacer(minLength: MobileDesign.Spacing.xLarge)
            HStack {
                MobileHomeMenu(showsSpaces: showsSpaces, open: actions.open)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MobileHomeMetrics.margin)
            .padding(.bottom, MobileDesign.Spacing.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

/// What Home's buttons do.
struct MobileHomeActions {
    /// Pushes a screen, or opens the Space where the screen has the room.
    let open: (MobileShellRoute) -> Void
    /// Voice mode: the assistant, which opens a source the learner names, goes
    /// through today's cards when asked, and takes typed questions and answers.
    let talk: () -> Void
}

enum MobileHomeMetrics {
    static let margin: CGFloat = 20
    /// The quiet fill Home's secondary controls sit on.
    static let fill = Color.primary.opacity(0.06)
    static let voiceButtonSize: CGFloat = 176
}

// MARK: - Voice

/// The voice button: a dark circle with the waveform, on a soft halo. A tap
/// starts voice mode.
struct MobileHomeVoiceButton: View {
    let talk: () -> Void

    var body: some View {
        Button(action: talk) {
            Image(systemName: "waveform")
                .font(.system(size: 60, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(width: MobileHomeMetrics.voiceButtonSize, height: MobileHomeMetrics.voiceButtonSize)
                .background(Color.primary, in: Circle())
                .padding(22)
                .background(MobileHomeMetrics.fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(MobileHomePressStyle())
        .accessibilityLabel("Talk to ForeverLM")
        .accessibilityHint("Talk, or type when you can't. Ask about a source by name, or go through today's cards.")
        .accessibilityIdentifier("home.voice")
    }
}

// MARK: - Today's cards

/// Today's cards as one quiet pill: the count, which opens the card review
/// (tap through the cards, pictures and all). Drawn only while cards wait.
struct MobileHomeCardsPill: View {
    let count: Int
    let review: () -> Void

    var body: some View {
        Button(action: review) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .accessibilityHidden(true)
                Text(count == 1 ? "1 card" : "\(count) cards")
                    .monospacedDigit()
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 22)
            .frame(height: 48)
            .background(MobileHomeMetrics.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(MobileHomePressStyle())
        .accessibilityLabel(count == 1 ? "Review 1 card" : "Review \(count) cards")
        .accessibilityIdentifier("home.review")
    }
}

// MARK: - The menu

/// Everything that is not voice or today's cards, tucked into one menu at the
/// foot of Home: notebooks, the library and its lists, the Space, Memory and
/// Settings.
struct MobileHomeMenu: View {
    let showsSpaces: Bool
    let open: (MobileShellRoute) -> Void

    var body: some View {
        Menu {
            Section {
                Button("Notebooks", systemImage: MobileNotebookGlyph.symbolName) { open(.notebooks(.all)) }
                Button("Library", systemImage: "books.vertical") { open(.library) }
                Button("To Read", systemImage: "bookmark") { open(.toRead) }
                Button("Follow Up", systemImage: "flag") { open(.followUp) }
                if showsSpaces {
                    Button("Spaces", systemImage: "square.on.square") { open(.space(nil)) }
                }
            }
            Section {
                Button("Memory", systemImage: MemoryReviewSession.sidebarIcon) { open(.memory) }
                Button("Settings", systemImage: "gearshape") { open(.settings) }
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .background(MobileHomeMetrics.fill, in: Circle())
                .contentShape(Circle())
        }
        .tint(.primary)
        .accessibilityLabel("More")
        .accessibilityIdentifier("home.menu")
    }
}

/// A control that gives a little under the finger.
struct MobileHomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
