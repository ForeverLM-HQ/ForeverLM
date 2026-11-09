import SwiftUI

/// Home, drawn as ChatGPT's app draws its own (product owner, 2026-11-09, with
/// both of ChatGPT's screens beside ours: "can you please just copy the design
/// from the ChatGPT app a bit better", then "essentially, be the same"): a round
/// menu button at the top left, three quiet suggestion rows above one composer
/// pill (a field to type into, and a round button that talks), and everything
/// else in a side drawer the Home slides over. It stays what it was before for
/// a voice interface (2026-11-09: "mostly a voice interface … the other things
/// … tucked away"): the ForeverLM mark in the middle still starts a call, and
/// so does the round button while the field is empty.
///
/// The drawer holds what Home's old menu held, laid out as ChatGPT's sidebar:
/// the title with a search circle, one row per place (notebooks, the library,
/// To Read, Follow Up, the Space, Review Cards, Memory), a rule, the notebooks
/// worked in last with "See all…", and at the foot a Voice pill and Settings.
/// Swipe right opens it, swipe left or a tap on Home closes it.
///
/// It draws only what it is handed, so Home (`MobileNotebookHomeView`) and the
/// DEBUG harness (`MobileHomeHarness`) draw the same screen.
struct MobileHomeDashboard<Top: View>: View {
    /// Whether the drawer offers the Space (it opens on generation 2).
    let showsSpaces: Bool
    /// The notebooks worked in last, newest first, for the drawer's list.
    var recents: [MobileHomeRecent] = []
    let actions: MobileHomeActions
    /// What sits above the mark while it matters: a running bout.
    @ViewBuilder let top: () -> Top

    @State private var drawerIsOpen = false
    @GestureState private var dragOffset: CGFloat = 0
    @State private var draft = ""
    @FocusState private var composerIsFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let drawerWidth = min(proxy.size.width * MobileHomeMetrics.drawerShare, MobileHomeMetrics.drawerMaxWidth)
            let progress = drawerProgress(width: drawerWidth)
            ZStack(alignment: .leading) {
                MobileHomeDrawer(
                    showsSpaces: showsSpaces,
                    recents: recents,
                    open: go,
                    talk: { close(); actions.talk() }
                )
                .padding(.top, insets.top)
                .padding(.bottom, insets.bottom)
                .frame(width: drawerWidth, height: proxy.size.height, alignment: .top)
                .background(Color(uiColor: .systemBackground))
                .allowsHitTesting(drawerIsOpen)
                .accessibilityHidden(!drawerIsOpen)

                home
                    .padding(.top, insets.top)
                    .padding(.bottom, insets.bottom)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(Color(uiColor: .systemBackground))
                    .overlay {
                        // While the drawer is out, Home is one big "close".
                        if drawerIsOpen {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture(perform: close)
                                .accessibilityHidden(true)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: MobileHomeMetrics.slidCorner * progress, style: .continuous))
                    .shadow(color: .black.opacity(0.14 * progress), radius: 24)
                    .offset(x: drawerWidth * progress)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .background(Color(uiColor: .systemBackground))
            .simultaneousGesture(drawerDrag(width: drawerWidth))
        }
        .ignoresSafeArea(.container)
    }

    // MARK: - Home

    private var home: some View {
        VStack(spacing: 0) {
            HStack {
                MobileHomeCircleButton(label: "Menu", identifier: "home.menu", action: openDrawer) {
                    MobileHomeMenuGlyph()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MobileHomeMetrics.margin)
            .padding(.top, MobileDesign.Spacing.small)

            top()
                .padding(.horizontal, MobileHomeMetrics.margin)
                .padding(.top, MobileDesign.Spacing.small)

            Spacer(minLength: MobileDesign.Spacing.medium)
            if !composerIsFocused {
                MobileHomeVoiceButton(talk: actions.talk, markWidth: MobileHomeMetrics.voiceMarkWidth)
                    .transition(.opacity)
                Spacer(minLength: MobileDesign.Spacing.medium)
            }

            suggestions
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: composerIsFocused)
    }

    /// Three ways in, each a place Home can open, in ChatGPT's suggestion rows:
    /// a glyph, a line of text, nothing else.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(MobileHomeSuggestion.allCases) { suggestion in
                Button { go(suggestion.route) } label: {
                    HStack(spacing: MobileDesign.Spacing.large) {
                        Image(systemName: suggestion.symbol)
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .frame(width: 30)
                        Text(suggestion.title)
                            .font(.system(size: 18))
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(suggestion.identifier)
            }
        }
        .padding(.horizontal, MobileHomeMetrics.margin + MobileDesign.Spacing.small)
        .padding(.bottom, MobileDesign.Spacing.medium)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// ChatGPT's composer: one capsule, the field, and one round button that
    /// talks while there is nothing typed and sends once there is.
    private var composer: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            TextField("Ask ForeverLM", text: $draft)
                .font(.system(size: 18))
                .focused($composerIsFocused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .padding(.leading, MobileDesign.Spacing.large)
                .accessibilityIdentifier("home.composer.field")
            Button(action: { canSend ? sendDraft() : actions.talk() }) {
                Image(systemName: canSend ? "arrow.up" : "waveform")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.primary))
                    .contentShape(Circle())
            }
            .buttonStyle(MobileHomePressStyle())
            .accessibilityLabel(canSend ? "Send" : "Talk to ForeverLM")
            .accessibilityIdentifier(canSend ? "home.composer.send" : "home.composer.voice")
        }
        .padding(6)
        .background(Capsule().fill(Color(uiColor: .systemBackground)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 3)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.bottom, MobileDesign.Spacing.small)
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        composerIsFocused = false
        actions.send(text)
    }

    // MARK: - The drawer

    private func drawerProgress(width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(max(((drawerIsOpen ? width : 0) + dragOffset) / width, 0), 1)
    }

    private func openDrawer() {
        composerIsFocused = false
        withAnimation(.snappy(duration: 0.3)) { drawerIsOpen = true }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.3)) { drawerIsOpen = false }
    }

    /// A place from the drawer or a suggestion: the drawer slides back as the
    /// screen is pushed, so Home is closed again when Back returns to it.
    private func go(_ route: MobileShellRoute) {
        close()
        actions.open(route)
    }

    private func drawerDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .updating($dragOffset) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let landed = (drawerIsOpen ? width : 0) + value.predictedEndTranslation.width
                let opens = landed > width / 2
                if opens { composerIsFocused = false }
                withAnimation(.snappy(duration: 0.3)) { drawerIsOpen = opens }
            }
    }
}

/// A notebook the drawer lists under its rule: worked in lately.
struct MobileHomeRecent: Identifiable, Equatable {
    let id: String
    let title: String
}

/// What Home's buttons do.
struct MobileHomeActions {
    /// Pushes a screen, or opens the Space where the screen has the room.
    let open: (MobileShellRoute) -> Void
    /// Voice mode: the assistant, which opens a source the learner names, goes
    /// through today's cards when asked, and takes typed questions and answers.
    let talk: () -> Void
    /// Something typed in the composer: it starts the assistant's call and is
    /// asked in it, as the voice screen's typing field asks.
    let send: (String) -> Void
}

enum MobileHomeMetrics {
    static let margin: CGFloat = 20
    /// The mark Home keeps in its middle.
    static let voiceMarkWidth: CGFloat = 210
    /// The drawer's width: most of the screen, as ChatGPT's, and no wider on an iPad.
    static let drawerShare: CGFloat = 0.8
    static let drawerMaxWidth: CGFloat = 360
    /// The corner Home takes on while it is slid over.
    static let slidCorner: CGFloat = 42
    static let circle: CGFloat = 50
}

/// The three rows above the composer.
enum MobileHomeSuggestion: CaseIterable, Identifiable {
    case cards, notebooks, toRead

    var id: Self { self }

    var title: String {
        switch self {
        case .cards: "Go through today's cards"
        case .notebooks: "Pick up a notebook"
        case .toRead: "Read what you saved"
        }
    }

    var symbol: String {
        switch self {
        case .cards: "rectangle.stack"
        case .notebooks: MobileNotebookGlyph.symbolName
        case .toRead: "bookmark"
        }
    }

    var route: MobileShellRoute {
        switch self {
        case .cards: .cardReview(.allNotebooks)
        case .notebooks: .notebooks(.all)
        case .toRead: .toRead
        }
    }

    var identifier: String {
        switch self {
        case .cards: "home.suggestion.cards"
        case .notebooks: "home.suggestion.notebooks"
        case .toRead: "home.suggestion.toRead"
        }
    }
}

// MARK: - Controls

/// ChatGPT's round button: a white disc with a hairline and a soft shadow.
struct MobileHomeCircleButton<Content: View>: View {
    let label: String
    let identifier: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .foregroundStyle(.primary)
                .frame(width: MobileHomeMetrics.circle, height: MobileHomeMetrics.circle)
                .background(Circle().fill(Color(uiColor: .systemBackground)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(MobileHomePressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// The menu button's glyph in ChatGPT's app: a long bar over a short one.
struct MobileHomeMenuGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule().frame(width: 21, height: 2.5)
            Capsule().frame(width: 13, height: 2.5)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Drawer

/// ChatGPT's sidebar: a bold title with a search circle, a column of rows
/// (a glyph and a name each), a rule, the recent ones in plain text with
/// "See all…", and at the foot a pill and a round button.
struct MobileHomeDrawer: View {
    let showsSpaces: Bool
    let recents: [MobileHomeRecent]
    let open: (MobileShellRoute) -> Void
    let talk: () -> Void

    private static let side: CGFloat = 24

    private struct Place: Identifiable {
        let title: String
        let symbol: String
        let route: MobileShellRoute
        let identifier: String
        var id: String { identifier }
    }

    private var places: [Place] {
        var places = [
            Place(title: "Notebooks", symbol: MobileNotebookGlyph.symbolName, route: .notebooks(.all), identifier: "home.drawer.notebooks"),
            Place(title: "Library", symbol: "books.vertical", route: .library, identifier: "home.drawer.library"),
            Place(title: "To Read", symbol: "bookmark", route: .toRead, identifier: "home.drawer.toRead"),
            Place(title: "Follow Up", symbol: "flag", route: .followUp, identifier: "home.drawer.followUp"),
        ]
        if showsSpaces {
            places.append(Place(title: "Spaces", symbol: "square.on.square", route: .space(nil), identifier: "home.drawer.spaces"))
        }
        places.append(Place(title: "Review Cards", symbol: "rectangle.stack", route: .cardReview(.allNotebooks), identifier: "home.drawer.cards"))
        places.append(Place(title: "Memory", symbol: MemoryReviewSession.sidebarIcon, route: .memory, identifier: "home.drawer.memory"))
        return places
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ForeverLM")
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: MobileDesign.Spacing.small)
                MobileHomeCircleButton(label: "Search", identifier: "home.drawer.search", action: { open(.library) }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .medium))
                }
            }
            .padding(.horizontal, Self.side)
            .padding(.top, MobileDesign.Spacing.small)
            .padding(.bottom, MobileDesign.Spacing.small)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(places) { place in
                        Button { open(place.route) } label: {
                            HStack(spacing: 18) {
                                Image(systemName: place.symbol)
                                    .font(.system(size: 22))
                                    .frame(width: 32)
                                Text(place.title)
                                    .font(.system(size: 19, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.primary)
                            .frame(minHeight: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(place.identifier)
                    }

                    if !recents.isEmpty {
                        Divider()
                            .padding(.vertical, MobileDesign.Spacing.large)
                        ForEach(recents) { recent in
                            Button { open(.notebook(recent.id)) } label: {
                                Text(recent.title.isEmpty ? "Untitled notebook" : recent.title)
                                    .font(.system(size: 18))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("home.drawer.recent")
                        }
                        Button { open(.notebooks(.all)) } label: {
                            Text("See all…")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.drawer.seeAll")
                    }
                }
                .padding(.horizontal, Self.side)
            }
            .scrollIndicators(.hidden)

            HStack {
                Button(action: talk) {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform")
                            .font(.system(size: 19, weight: .semibold))
                        Text("Voice")
                            .font(.system(size: 19, weight: .semibold))
                    }
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .padding(.horizontal, 26)
                    .frame(height: 56)
                    .background(Capsule().fill(Color.primary))
                    .contentShape(Capsule())
                }
                .buttonStyle(MobileHomePressStyle())
                .accessibilityIdentifier("home.drawer.voice")
                Spacer(minLength: MobileDesign.Spacing.small)
                MobileHomeCircleButton(label: "Settings", identifier: "home.drawer.settings", action: { open(.settings) }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 21, weight: .medium))
                }
            }
            .padding(.horizontal, Self.side)
            .padding(.top, MobileDesign.Spacing.small)
            .padding(.bottom, MobileDesign.Spacing.small)
        }
    }
}

// MARK: - Voice

/// The mark in Home's middle: ForeverLM's iridescent infinity on a soft glow
/// in its own colours that breathes slowly (still under Reduce Motion)
/// (product owner, 2026-11-09: "make the voice icon nicer and use the foreverlm
/// logo for it"). A tap starts voice mode.
struct MobileHomeVoiceButton: View {
    let talk: () -> Void
    var markWidth: CGFloat = 270

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
                // The glow was drawn for a 270-point mark.
                .scaleEffect((breathes ? 1.08 : 0.94) * markWidth / 270)
                // On black the light glow turns to haze: a quieter one there.
                .opacity((breathes ? 1 : 0.8) * (colorScheme == .dark ? 0.38 : 1))

                Image("BrandMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: markWidth)
                    .scaleEffect(breathes ? 1.025 : 0.985)
                    .shadow(color: Self.glow[0].opacity(0.35), radius: 22, y: 10)
            }
            .frame(width: markWidth + 60, height: markWidth * 0.75)
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

/// A control that gives a little under the finger.
struct MobileHomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
