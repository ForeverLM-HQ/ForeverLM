import SwiftUI

/// Home, drawn as ChatGPT's app draws its own (product owner, 2026-11-09, with
/// both of ChatGPT's screens beside ours: "can you please just copy the design
/// from the ChatGPT app a bit better", then "essentially, be the same"): a round
/// menu button at the top left, three quiet suggestion rows above one composer
/// pill (a field to type into, and a round button that talks), and everything
/// else in a side drawer the Home slides over. It stays what it was before for
/// a voice interface (2026-11-09: "mostly a voice interface … the other things
/// … tucked away"): the round button starts a call while the field is empty,
/// and so does the drawer's Voice pill. The middle is left empty, as ChatGPT's
/// is: the ForeverLM mark is the voice screen's (`VoiceSessionSurface`), not
/// Home's (product owner, 2026-11-09: "let's not have that logo so prominently,
/// except when we go into voice mode").
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
    /// What sits under the menu button while it matters: a running bout.
    @ViewBuilder let top: () -> Top

    @State private var drawerIsOpen = false
    @GestureState private var dragOffset: CGFloat = 0
    @State private var draft = ""
    @FocusState private var composerIsFocused: Bool
    /// Home's words follow the text size the learner set in iOS Settings; they
    /// were fixed point sizes, so Larger Text changed every screen but this one.
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 20

    var body: some View {
        // Home and the drawer are laid out inside the safe area, and only what
        // is painted behind them runs to the screen's edges. The whole screen
        // ignored the safe area before and padded itself by the reader's insets,
        // which are zero for a reader that ignores it: the menu button sat under
        // the clock, and the composer on the home indicator. The shell keeps
        // both above its playback bar (`MobileShellBarClearance`).
        GeometryReader { proxy in
            let drawerWidth = min(proxy.size.width * MobileHomeMetrics.drawerShare, MobileHomeMetrics.drawerMaxWidth)
            let progress = drawerProgress(width: drawerWidth)
            ZStack(alignment: .leading) {
                MobileHomeDrawer(
                    showsSpaces: showsSpaces,
                    recents: recents,
                    open: go,
                    talk: { close(); actions.talk() }
                )
                .frame(width: drawerWidth, height: proxy.size.height, alignment: .top)
                .allowsHitTesting(drawerIsOpen)
                .accessibilityHidden(!drawerIsOpen)

                home
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background {
                        // Home's sheet: the whole screen, its corners rounding as it slides over.
                        // The hairline is what shows its edge in dark mode, where a
                        // black shadow on a black drawer draws nothing.
                        RoundedRectangle(cornerRadius: MobileHomeMetrics.slidCorner * progress, style: .continuous)
                            .fill(Color(uiColor: .systemBackground))
                            .overlay {
                                RoundedRectangle(cornerRadius: MobileHomeMetrics.slidCorner * progress, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.14 * progress), lineWidth: 0.5)
                            }
                            .shadow(color: .black.opacity(0.14 * progress), radius: 24)
                            .ignoresSafeArea()
                    }
                    .overlay {
                        // While the drawer is out, Home is one big "close".
                        if drawerIsOpen {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture(perform: close)
                                .ignoresSafeArea()
                                .accessibilityHidden(true)
                        }
                    }
                    .offset(x: drawerWidth * progress)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .background(Color(uiColor: .systemBackground), ignoresSafeAreaEdges: .all)
            .simultaneousGesture(drawerDrag(width: drawerWidth))
        }
        // Past this the drawer's one-line rows have no room left to grow into.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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

            // On an iPad the rows and the composer keep a readable measure in
            // the middle, as ChatGPT's do, instead of a field a thousand points wide.
            VStack(spacing: 0) {
                suggestions
                composer
            }
            .mobileReadableWidth()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Three ways in, each a place Home can open, in ChatGPT's suggestion rows:
    /// a glyph, a line of text, nothing else.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(MobileHomeSuggestion.allCases) { suggestion in
                Button { go(suggestion.route) } label: {
                    HStack(spacing: MobileDesign.Spacing.large) {
                        Image(systemName: suggestion.symbol)
                            .font(.system(size: glyphSize))
                            .foregroundStyle(.secondary)
                            .frame(width: glyphSize * 1.5)
                        Text(suggestion.title)
                            .font(.system(size: textSize))
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
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
        HStack(alignment: .bottom, spacing: MobileDesign.Spacing.small) {
            // The field grows with a long question, up to five lines, as
            // ChatGPT's does; Return starts a new line and the button sends.
            TextField("Ask ForeverLM", text: $draft, axis: .vertical)
                .font(.system(size: textSize))
                .lineLimit(1...5)
                .focused($composerIsFocused)
                .padding(.leading, MobileDesign.Spacing.large)
                .padding(.vertical, 11)
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
        .background(composerShape.fill(MobileHomeMetrics.raisedSurface))
        .overlay(composerShape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 3)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.bottom, MobileDesign.Spacing.small)
    }

    /// A capsule while the field is one line, the same corners once it grows.
    private var composerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MobileHomeMetrics.composerCorner, style: .continuous)
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
    /// The drawer's width: most of the screen, as ChatGPT's, and no wider on an iPad.
    static let drawerShare: CGFloat = 0.8
    static let drawerMaxWidth: CGFloat = 360
    /// The corner Home takes on while it is slid over.
    static let slidCorner: CGFloat = 42
    static let circle: CGFloat = 50
    /// Half the one-line composer's height, so one line reads as a capsule.
    static let composerCorner: CGFloat = 28
    /// What the composer and the round buttons are filled with: the page's own
    /// white lifted by a shadow in light mode, a raised grey in dark mode, where
    /// a shadow shows nothing and black on black left only a hairline.
    static let raisedSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemBackground
    })
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
                .background(Circle().fill(MobileHomeMetrics.raisedSurface))
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

    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var placeSize: CGFloat = 19
    @ScaledMetric(relativeTo: .body) private var placeGlyphSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var recentSize: CGFloat = 18

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
                    .font(.system(size: titleSize, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
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
                                    .font(.system(size: placeGlyphSize))
                                    .frame(width: placeGlyphSize * 1.45)
                                Text(place.title)
                                    .font(.system(size: placeSize, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
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
                                    .font(.system(size: recentSize))
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
                                .font(.system(size: recentSize))
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
                            .font(.system(size: placeSize, weight: .semibold))
                        Text("Voice")
                            .font(.system(size: placeSize, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .padding(.horizontal, 26)
                    .frame(minHeight: 56)
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

/// A control that gives a little under the finger.
struct MobileHomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
