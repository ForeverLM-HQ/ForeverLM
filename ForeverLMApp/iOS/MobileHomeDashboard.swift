import SwiftUI

/// Home, rebuilt around what the phone is for (product owner, 2026-11-09: "the
/// main use cases for me are voice mode, gym mode …; doing memory review either
/// via voice mode or via tapping the flashcards and looking at the images", "voice
/// mode to chat with particular sources in the car", and papers "a bit less
/// prominently displayed"; the old Home "looks terrible", make it look like
/// NotebookLM's; "we shouldn't really have separate modes for voice and drive and
/// gym"; the settings and plus buttons at the top waste space). From the top: the
/// day's date; today's cards, with Review and By Voice; Voice, the one voice mode,
/// talked or typed to; the notebooks as cover cards, two to a row, with + and See
/// All; and the library as a quiet row of chips at the foot.
///
/// It draws only what it is handed, so Home (`MobileNotebookHomeView`) and the
/// DEBUG harness (`MobileHomeHarness`) draw the same screen. Its sections are
/// rows of Home's plain list, which keeps Home's search and pull to refresh.
struct MobileHomeDashboard<NotebookMenu: View>: View {
    /// Today's cards; nil until the phone knows (nothing synced yet).
    let cards: MemoryCardDayCounts?
    let notebooks: [MobileHomeNotebookItem]
    /// Whether All Notebooks lists more than `notebooks` shows.
    let hasMoreNotebooks: Bool
    let isSyncing: Bool
    /// Whether the Spaces chip shows (the Space opens on generation 2).
    let showsSpaces: Bool
    /// How many notebook cards share a row.
    let columns: Int
    let actions: MobileHomeActions
    /// A notebook card's long-press menu (Pin, Rename, Archive…).
    @ViewBuilder let notebookMenu: (MobileCloudNotebook) -> NotebookMenu

    var body: some View {
        Group {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .modifier(MobileHomeRow(top: MobileDesign.Spacing.small, bottom: 0))

            if let cards {
                MobileHomeReviewCard(cards: cards, open: actions.open, reviewByVoice: actions.reviewByVoice)
                    .modifier(MobileHomeRow(top: MobileDesign.Spacing.small))
            }

            MobileHomeVoiceCard(talk: actions.talk)
                .modifier(MobileHomeRow(top: MobileDesign.Spacing.small))

            notebooksHeader
                .modifier(MobileHomeRow(top: MobileDesign.Spacing.xLarge, bottom: 0))
            notebookGrid
                .modifier(MobileHomeRow(top: MobileDesign.Spacing.small))

            MobileHomeSectionHeader("Library")
                .modifier(MobileHomeRow(top: MobileDesign.Spacing.xLarge, bottom: 0))
            MobileHomeLibraryChips(showsSpaces: showsSpaces, open: actions.open, newPage: actions.newPage, dailyNote: actions.dailyNote)
                .modifier(MobileHomeRow(top: MobileDesign.Spacing.small, bottom: MobileDesign.Spacing.large, horizontal: 0))
        }
    }

    private var notebooksHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            MobileHomeSectionHeader("Notebooks")
            Spacer(minLength: 0)
            Button(action: actions.newNotebook) {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(MobileHomeMetrics.fill, in: Circle())
            }
            .buttonStyle(MobileHomePressStyle())
            .accessibilityLabel("New notebook")
            .accessibilityIdentifier("home.newNotebook")
            if hasMoreNotebooks {
                Button("See All") { actions.open(.notebooks(.all)) }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .padding(.leading, MobileDesign.Spacing.small)
                    .accessibilityIdentifier("home.allNotebooks")
            }
        }
    }

    @ViewBuilder
    private var notebookGrid: some View {
        if notebooks.isEmpty {
            MobileHomeEmptyNotebooks(isSyncing: isSyncing, newNotebook: actions.newNotebook)
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: MobileDesign.Spacing.medium, alignment: .top), count: max(columns, 1)),
                alignment: .leading,
                spacing: MobileDesign.Spacing.medium
            ) {
                ForEach(notebooks) { item in
                    MobileNotebookGalleryCard(
                        notebook: item.notebook,
                        sourceCount: item.sourceCount,
                        lastActivity: item.lastActivity,
                        overviewIsPlaying: item.overviewIsPlaying,
                        hasOverview: item.overviewSourceID != nil,
                        isPreparingOverview: item.isPreparingOverview,
                        onOpen: { actions.open(.notebook(item.notebook.id)) },
                        onPlay: {
                            if let sourceID = item.overviewSourceID { actions.playOverview(sourceID) }
                        },
                        isCompact: true
                    )
                    .contextMenu { notebookMenu(item.notebook) }
                }
            }
        }
    }
}

/// One notebook card on Home.
struct MobileHomeNotebookItem: Identifiable {
    let notebook: MobileCloudNotebook
    let sourceCount: Int
    let lastActivity: Date
    /// The notebook's audio overview, which the card's ▶ plays.
    var overviewSourceID: String? = nil
    var overviewIsPlaying = false
    var isPreparingOverview = false
    var id: String { notebook.id }
}

/// What Home's buttons do.
struct MobileHomeActions {
    /// Pushes a screen, or opens the Space where the screen has the room.
    let open: (MobileShellRoute) -> Void
    /// Review by Voice over every notebook.
    let reviewByVoice: () -> Void
    /// Voice mode: the assistant, which finds and opens a source the learner
    /// names ("let's talk about the oocytes paper"), hands free, and takes
    /// typed questions and answers too.
    let talk: () -> Void
    let newNotebook: () -> Void
    /// The Spaces chip's menu: a new page, and today's daily note.
    var newPage: (() -> Void)? = nil
    var dailyNote: (() -> Void)? = nil
    /// A card's ▶: the notebook's audio overview, by its source id.
    var playOverview: (String) -> Void = { _ in }
}

/// A row of Home's plain list with nothing of the list's own: no separator, no
/// background, Home's margins.
struct MobileHomeRow: ViewModifier {
    var top: CGFloat = MobileDesign.Spacing.small
    var bottom: CGFloat = MobileDesign.Spacing.small
    var horizontal: CGFloat = MobileHomeMetrics.margin

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: top, leading: horizontal, bottom: bottom, trailing: horizontal))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

enum MobileHomeMetrics {
    static let margin: CGFloat = 20
    static let cardRadius: CGFloat = 26
    static let tileRadius: CGFloat = 22
    /// The quiet fill every Home card sits on.
    static let fill = Color.primary.opacity(0.045)
}

// MARK: - Today's cards

/// Today's cards, the first thing on Home: how many, and the two ways to go
/// through them, Review (the cards, pictures and all) and By Voice. With nothing
/// due it says so and offers practice. A tap anywhere else opens Memory.
struct MobileHomeReviewCard: View {
    let cards: MemoryCardDayCounts
    let open: (MobileShellRoute) -> Void
    let reviewByVoice: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.large) {
            HStack(alignment: .firstTextBaseline) {
                MobileHomeLabel(title: "Memory", systemImage: MemoryReviewSession.sidebarIcon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if cards.toCheck > 0 {
                    Text("\(cards.toCheck.formatted()) to check")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            if cards.today > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(cards.today)")
                            .font(.system(size: 52, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(cards.today == 1 ? "card today" : "cards today")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if let line = cards.todayLine, cards.new > 0 {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: MobileDesign.Spacing.small) {
                    Button { open(.cardReview(.allNotebooks)) } label: {
                        MobileHomeLabel(title: "Review", systemImage: "rectangle.stack")
                    }
                    .buttonStyle(MobileHomePillStyle(isPrimary: true))
                    .accessibilityIdentifier("home.review")

                    Button(action: reviewByVoice) {
                        MobileHomeLabel(title: "By Voice", systemImage: "waveform")
                    }
                    .buttonStyle(MobileHomePillStyle(isPrimary: false))
                    .accessibilityIdentifier("home.reviewByVoice")
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("All caught up")
                        .font(.title2.weight(.semibold))
                    Text(cards.practice > 0 ? "Nothing due today. Practice the new cards if you like." : "Nothing due today.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if cards.practice > 0 {
                    Button { open(.cardPractice(.allNotebooks)) } label: {
                        MobileHomeLabel(title: "Practice", systemImage: "rectangle.stack")
                    }
                    .buttonStyle(MobileHomePillStyle(isPrimary: false))
                    .accessibilityIdentifier("home.practice")
                }
            }
        }
        .padding(MobileDesign.Spacing.xLarge - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MobileHomeMetrics.fill, in: RoundedRectangle(cornerRadius: MobileHomeMetrics.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: MobileHomeMetrics.cardRadius, style: .continuous))
        .onTapGesture { open(.memory) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.memory")
    }
}

/// A glyph and its words, closer together than `Label` sets them.
struct MobileHomeLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .imageScale(.medium)
                .accessibilityHidden(true)
            Text(title)
        }
    }
}

/// A capsule button of Home: the dark one, of which a screen has one, and the quiet one.
struct MobileHomePillStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isPrimary ? Color(uiColor: .systemBackground) : Color.primary)
            .padding(.horizontal, 20)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background(
                isPrimary ? Color.primary : Color.primary.opacity(0.07),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Voice

/// Voice, the one voice mode (product owner, 2026-11-09: voice, the car and the
/// gym "are really all the same"): talk about anything, a source by its name, or
/// today's cards, hands free in the car; at the gym, type instead (the voice
/// screen's field, `MobileVoiceTypeField`). One wide card, its waveform the dark
/// round button.
struct MobileHomeVoiceCard: View {
    let talk: () -> Void

    var body: some View {
        Button(action: talk) {
            HStack(spacing: MobileDesign.Spacing.large) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: 52, height: 52)
                    .background(Color.primary, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Talk about anything or name a source. Type when you can’t talk.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(MobileDesign.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MobileHomeMetrics.fill, in: RoundedRectangle(cornerRadius: MobileHomeMetrics.cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: MobileHomeMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(MobileHomePressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice. Talk about anything or name a source; type when you can’t talk.")
        .accessibilityIdentifier("home.voice")
    }
}

/// A card that gives a little under the finger.
struct MobileHomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Notebooks

struct MobileHomeEmptyNotebooks: View {
    let isSyncing: Bool
    let newNotebook: () -> Void

    var body: some View {
        Button(action: newNotebook) {
            HStack(spacing: MobileDesign.Spacing.medium) {
                Image(systemName: isSyncing ? "arrow.triangle.2.circlepath" : "plus")
                    .font(.title3.weight(.medium))
                    .frame(width: 44, height: 44)
                    .background(Color(uiColor: .systemBackground), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(isSyncing ? "Syncing your notebooks" : "New notebook")
                        .font(.headline)
                    Text(isSyncing ? "They appear here as they arrive." : "Gather sources on one question.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(MobileDesign.Spacing.large)
            .background(MobileHomeMetrics.fill, in: RoundedRectangle(cornerRadius: MobileHomeMetrics.tileRadius, style: .continuous))
        }
        .buttonStyle(MobileHomePressStyle())
        .disabled(isSyncing)
    }
}

// MARK: - Library

/// The library at the foot of Home: papers and every other source, To Read,
/// Follow Up and the Space, as chips in one row that scrolls sideways.
struct MobileHomeLibraryChips: View {
    let showsSpaces: Bool
    let open: (MobileShellRoute) -> Void
    var newPage: (() -> Void)? = nil
    var dailyNote: (() -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MobileDesign.Spacing.small) {
                chip("All Sources", "books.vertical", .library, id: "home.sources")
                chip("To Read", "bookmark", .toRead, id: "home.toRead")
                chip("Follow Up", "flag", .followUp, id: "home.followUp")
                if showsSpaces {
                    chip("Spaces", "square.on.square", .space(nil), id: "home.space")
                        .contextMenu {
                            if let newPage {
                                Button("New Page", systemImage: "square.and.pencil", action: newPage)
                            }
                            if let dailyNote {
                                Button("Daily Notes", systemImage: "calendar", action: dailyNote)
                            }
                        }
                }
            }
            .padding(.horizontal, MobileHomeMetrics.margin)
        }
    }

    private func chip(_ title: String, _ systemImage: String, _ route: MobileShellRoute, id: String) -> some View {
        Button { open(route) } label: {
            MobileHomeLabel(title: title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(MobileHomeMetrics.fill, in: Capsule())
        }
        .buttonStyle(MobileHomePressStyle())
        .accessibilityIdentifier(id)
    }
}
