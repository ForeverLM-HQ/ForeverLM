import SwiftUI

/// Home, a voice interface (product owner, 2026-11-09, after a day of trimming
/// it: "the main use cases for me are voice mode, gym mode …; doing memory review
/// either via voice mode or via tapping the flashcards", "voice and drive and gym
/// … are really all the same", "this is way too much text", "can it just be
/// mostly a voice interface? And then the other things … tucked away in the app,
/// just on an as needed basis").
///
/// One large voice button in the middle (talk, or type when you can't: the voice
/// screen has the field), and one menu at the foot holding the rest: notebooks,
/// the library, To Read, Follow Up, the Space, Memory (the card review that is
/// tapped through, pictures and all) and Settings. Voice opens a source the
/// learner names, and offers today's cards first when they are due ("maybe even
/// get rid of this cards stuff; do that voice only also by default").
///
/// It draws only what it is handed, so Home (`MobileNotebookHomeView`) and the
/// DEBUG harness (`MobileHomeHarness`) draw the same screen.
struct MobileHomeDashboard<Top: View>: View {
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
    static let voiceMarkWidth: CGFloat = 270
}

// MARK: - Voice

/// The voice button: ForeverLM's mark, the iridescent infinity, large on a soft
/// glow in its own colours that breathes slowly (still under Reduce Motion)
/// (product owner, 2026-11-09: "make the voice icon nicer and use the foreverlm
/// logo for it"). A tap starts voice mode.
struct MobileHomeVoiceButton: View {
    let talk: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var breathes = false

    /// The mark's own lilac, aqua and peach.
    private static let glow: [Color] = [
        Color(red: 0.78, green: 0.70, blue: 0.98),
        Color(red: 0.58, green: 0.88, blue: 0.93),
        Color(red: 0.99, green: 0.85, blue: 0.72),
    ]

    var body: some View {
        Button(action: talk) {
            ZStack {
                ZStack {
                    Circle()
                        .fill(Self.glow[0].opacity(0.55))
                        .frame(width: 210, height: 210)
                        .offset(x: -48, y: 8)
                    Circle()
                        .fill(Self.glow[1].opacity(0.45))
                        .frame(width: 190, height: 190)
                        .offset(x: 52, y: -10)
                    Circle()
                        .fill(Self.glow[2].opacity(0.40))
                        .frame(width: 160, height: 160)
                        .offset(x: 10, y: 40)
                }
                .blur(radius: 46)
                .scaleEffect(breathes ? 1.08 : 0.94)
                // On black the light glow turns to haze: a quieter one there.
                .opacity((breathes ? 1 : 0.8) * (colorScheme == .dark ? 0.38 : 1))

                Image("BrandMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: MobileHomeMetrics.voiceMarkWidth)
                    .scaleEffect(breathes ? 1.025 : 0.985)
                    .shadow(color: Self.glow[0].opacity(0.35), radius: 22, y: 10)
            }
            .frame(width: MobileHomeMetrics.voiceMarkWidth + 60, height: MobileHomeMetrics.voiceMarkWidth * 0.75)
            .contentShape(Rectangle())
        }
        .buttonStyle(MobileHomePressStyle())
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) { breathes = true }
        }
        .accessibilityLabel("Talk to ForeverLM")
        .accessibilityHint("Talk, or type when you can't. Ask about a source by name, or go through today's cards.")
        .accessibilityIdentifier("home.voice")
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
                // Today's cards tapped through, pictures and all (voice is the
                // default way through them).
                Button("Review Cards", systemImage: "rectangle.stack") { open(.cardReview(.allNotebooks)) }
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
