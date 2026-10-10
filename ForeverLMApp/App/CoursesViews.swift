import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Pane

/// The Courses pane (docs/courses-design.md): the list of every course as
/// cards, drawn beside the Space's sidebar, and one course's page once a
/// card is opened. A course is a structure over sources — its videos,
/// papers, book chapters and articles live under their own types in Sources,
/// and its quizzes are its own records (product owner, 2026-09-27: "course should
/// not live under sources … similar to Khan Academy") — and it stands beside
/// the notebooks and the pages rather than inside a notebook
/// (product owner, 2026-10-03: "courses should not be a part of notebooks; they
/// are kind of separate entities"). A window holding a notebook can still
/// show a course's page in its document slot, as any pane
/// (`StudioViewModel.openCourse`).
struct CoursesPane: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @State private var actions = CourseActionsModel()

    var body: some View {
        Group {
            // A team's course page shows while its team's library is open;
            // leaving that library goes back to the list.
            if let courseID = windowState.coursePageID,
               vm.allCourseGroupNames.contains(courseID),
               vm.courseOpensInActiveLibrary(courseID) {
                CoursePageView(courseID: courseID)
                    .id(courseID)
            } else {
                // The courses are in the Space (2026-10-09): its sidebar beside
                // the list, the Space's tabs on the chrome line over it.
                SpaceFrame(hub: .courses) {
                    CoursesHomeView()
                } header: {
                    ViewThatFits(in: .horizontal) {
                        SpaceTabBar(selected: .courses)
                        SpaceTabBar(selected: .courses, compact: true)
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(actions)
        .modifier(CourseAlerts(vm: vm, actions: actions))
        .studioCenterTabCloseChrome(for: .courses)
    }
}

/// The alerts and sheets a course's menus open, shared by the home's cards and
/// the course's page.
@MainActor
@Observable
final class CourseActionsModel {
    enum Alert: Equatable {
        case createCourse
        case rename(String)
        case instructors(String)
        case courseCode(String)
        case institution(String)
        case addPlaylist(String)
        case remove(String)
        case renameLecture(String)

        /// The course or lecture the alert is about.
        var subject: String? {
            switch self {
            case .createCourse: return nil
            case .rename(let id), .instructors(let id), .courseCode(let id), .institution(let id),
                 .addPlaylist(let id), .remove(let id), .renameLecture(let id):
                return id
            }
        }
    }

    var alert: Alert?
    var alertText = ""
    /// The course a textbook is being added to (docs/textbook-readings-design.md).
    var textbookTarget: TextbookSheetTarget?

    func present(_ alert: Alert, text: String = "") {
        alertText = text
        self.alert = alert
    }
}

// MARK: - Home

/// Every course, as cards: cover, title, where it comes from and how far the
/// learner is. A click opens the course's page. The list brings its header's
/// one action, the New Course menu.
struct CoursesHomeView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(CourseActionsModel.self) private var actions
    @State private var ownQuery = ""

    private var query: String { ownQuery }

    var body: some View {
        ScrollView {
            list
                .padding(StudioDesign.Spacing.xLarge)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("studio.courses.home")
    }

    private var list: some View {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let courses = vm.courseGroupNames(matching: words)
        return VStack(alignment: .leading, spacing: StudioDesign.Spacing.xLarge) {
            header
            if vm.shownCourseGroupNames.isEmpty {
                Text("No courses yet.")
                    .zoomedSystemFont(size: 15, weight: .medium)
                    .padding(.vertical, StudioDesign.Spacing.large)
                    .accessibilityIdentifier("studio.courses.empty")
            } else if courses.isEmpty {
                Text(words.isEmpty ? "No course here." : "No course matches “\(words)”.")
                    .zoomedSystemFont(size: 13)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: StudioDesign.Spacing.large, alignment: .top)],
                    alignment: .leading,
                    spacing: StudioDesign.Spacing.large
                ) {
                    ForEach(courses, id: \.self) { courseID in
                        CourseCard(courseID: courseID)
                    }
                }
                .animation(.easeInOut(duration: 0.16), value: courses)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: StudioDesign.Spacing.medium) {
            Spacer(minLength: StudioDesign.Spacing.large)
            if vm.shownCourseGroupNames.count > 6 {
                TextField("Search courses", text: $ownQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("studio.courses.search")
            }
            // One button for the two ways a course begins (2026-10-06,
            // the product owner: "cleaner and fewer buttons"): a chat that plans it,
            // which was the bordered Generate beside this, or a YouTube
            // playlist, which this button opened on its own.
            Menu {
                Button {
                    // A chat that plans the course with the learner before
                    // anything is written (CoursePlanningChat).
                    vm.startCoursePlanningChat()
                } label: {
                    Label("Plan with Chat\u{2026}", systemImage: "sparkles")
                }
                .help("Plan a course in chat, then generate it")
                .accessibilityIdentifier("studio.courses.generate")
                Button {
                    actions.present(.createCourse)
                } label: {
                    Label("From YouTube Playlist\u{2026}", systemImage: "play.rectangle")
                }
                .accessibilityIdentifier("studio.courses.newFromPlaylist")
            } label: {
                Label("New Course", systemImage: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .accessibilityIdentifier("studio.courses.new")
        }
    }
}

/// One course on the list: its cover, title, source and progress. Sources dropped on it join the course; another course
/// dropped on it takes its place; dragged onto a notebook it links the
/// course there.
struct CourseCard: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(CourseActionsModel.self) private var actions
    let courseID: String
    @State private var isHovering = false
    @State private var isTargeted = false

    var body: some View {
        let progress = vm.courseProgress(for: courseID)
        VStack(alignment: .leading, spacing: 0) {
            CourseCoverImage(artworkURL: vm.courseArtworkURL(courseID))
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipped()
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.xSmall) {
                HStack(alignment: .firstTextBaseline, spacing: StudioDesign.Spacing.small) {
                    Text(vm.courseDisplayName(courseID))
                        .zoomedSystemFont(size: 14, weight: .semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    // A team's course (docs/teams-design.md, decision 21):
                    // the mark a team's Doc carries, the team on hover.
                    if let team = vm.courseTeam(courseID) {
                        Spacer(minLength: 0)
                        Image(systemName: "person.2")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .help("In \(team.name)")
                            .accessibilityLabel("In \(team.name)")
                    }
                }
                if let subtitle = vm.courseDisplaySubtitle(courseID) {
                    Text(subtitle)
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: StudioDesign.Spacing.xSmall)
                if vm.isImportingCourse(courseID) {
                    HStack(spacing: StudioDesign.Spacing.small) {
                        ProgressView().controlSize(.small)
                        Text("Importing lectures…")
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("studio.courses.importing")
                } else if progress.total > 0 {
                    VStack(alignment: .leading, spacing: StudioDesign.Spacing.xSmall) {
                        CourseProgressBar(fraction: progress.fractionFinished, isComplete: progress.isComplete)
                        // The bar says how far; its words ("3 of 10 lectures
                        // finished") show under the pointer, in a slot that
                        // keeps the card's height (2026-10-06).
                        Text(progress.summary)
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                            .opacity(isHovering ? 1 : 0)
                    }
                }
            }
            .padding(StudioDesign.Spacing.medium)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovering ? 0.18 : 0.08), lineWidth: 1)
        )
        .overlay {
            StudioDropZoneOverlay(
                isActive: isTargeted,
                title: "Add to \(vm.courseDisplayName(courseID))",
                systemImage: "graduationcap",
                cornerRadius: 12,
                inset: 0
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { open() }
        .onHover { isHovering = $0 }
        .cursor(.pointingHand)
        .onDrag {
            let sourceIDs = vm.sourceIDsForGroupInOrder(courseID)
            StudioDragVisibility.shared.begin(articleIDs: sourceIDs, groupName: courseID)
            return groupDragProvider(for: StudioGroupTransfer(groupName: courseID, sourceIDs: sourceIDs))
        }
        .onDrop(of: CourseDropHandler.types, isTargeted: $isTargeted) { providers in
            StudioDragVisibility.shared.endSoon()
            return CourseDropHandler.handle(providers, courseID: courseID, vm: vm, actions: actions, reordersCourses: true)
        }
        .contextMenu {
            Button("Open Course") { open() }
            Divider()
            CourseMenuItems(courseID: courseID)
            Divider()
            Button {
                vm.sortCoursesByTitle()
            } label: {
                Label("Sort Courses by Title", systemImage: "arrow.up.arrow.down")
            }
        }
        // The help goes below the combined element: above it, every child
        // carried it and the card's help read once per line. A combined
        // element's tap is no press of its own, so the card's click is its
        // action; without it the button trait made a button that did nothing.
        .accessibilityElement(children: .combine)
        .help("Open the course")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("studio.courses.card")
        .accessibilityAction { open() }
    }

    /// A team's course opens in the team's library, which lists its rows.
    private func open() {
        if vm.courseTeamIDs[courseID] != nil {
            Task { await vm.openCourseInItsLibrary(courseID, in: windowState) }
        } else {
            vm.openCourse(courseID, in: windowState)
        }
    }
}

// MARK: - A course's page

/// One course, Khan Academy style (product owner, 2026-09-27): a header with the
/// course's progress and Continue, then a card per lecture — its video, its
/// assigned reading, its materials and its practice quiz — with the
/// checkpoint quizzes and the course test standing between and after them.
/// Every written quiz holds back what comes after it until it is completed
/// (`CourseGate`).
struct CoursePageView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(CourseActionsModel.self) private var actions
    let courseID: String
    @State private var isTargeted = false

    var body: some View {
        let path = vm.coursePath(for: courseID)
        let gate = vm.courseGate(for: path)
        ScrollView {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.large) {
                // In a notebook the page is a document in its slot, and the
                // course list has no place there: its × closes it.
                if windowState.notebook == nil {
                    backButton
                }
                CoursePageHeader(courseID: courseID, path: path, gate: gate)
                if let progress = vm.courseQuizWritingProgress[courseID] {
                    CourseActivityRow(text: progress.stage == .fetchingTranscripts
                        ? "Fetching transcripts…"
                        : progress.total == 1 ? "Writing quiz…" : "Writing quizzes \(progress.done) of \(progress.total)…")
                }
                if let stage = vm.textbookReadingStages[courseID] {
                    CourseActivityRow(text: stage.label)
                }
                if vm.courseLectureNamingIDs.contains(courseID) {
                    CourseActivityRow(text: "Retitling lectures…")
                }
                ForEach(path.blocks) { block in
                    switch block {
                    case .unit(let unit):
                        CourseUnitCard(courseID: courseID, unit: unit, gate: gate)
                    case .milestone(let entry):
                        CoursePathRow(
                            courseID: courseID,
                            entry: entry,
                            state: gate.state(of: entry),
                            tracksCompletion: gate.tracksCompletion(of: entry),
                            isNext: entry.id == gate.nextEntryID,
                            isMilestone: true
                        )
                            .padding(StudioDesign.Spacing.small)
                            // A neutral wash, not indigo (2026-10-06): lists
                            // are monochrome (ui-design.md).
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )
                    }
                }
                if path.blocks.isEmpty && path.furtherMaterial.isEmpty {
                    Text(vm.isImportingCourse(courseID) ? "Importing lectures…" : "No lectures yet.")
                        .zoomedSystemFont(size: 13)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, StudioDesign.Spacing.medium)
                }
                if !path.furtherMaterial.isEmpty {
                    VStack(alignment: .leading, spacing: StudioDesign.Spacing.xSmall) {
                        Text("More material")
                            .zoomedSystemFont(size: 12, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .padding(.leading, StudioDesign.Spacing.small)
                        ForEach(path.furtherMaterial) { article in
                            CourseLooseMaterialRow(courseID: courseID, article: article)
                        }
                    }
                }
            }
            .padding(StudioDesign.Spacing.xLarge)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .overlay {
            StudioDropZoneOverlay(
                isActive: isTargeted,
                title: "Add to \(vm.courseDisplayName(courseID))",
                systemImage: "graduationcap",
                cornerRadius: 12,
                inset: StudioDesign.Spacing.small
            )
        }
        .onDrop(of: CourseDropHandler.types, isTargeted: $isTargeted) { providers in
            StudioDragVisibility.shared.endSoon()
            return CourseDropHandler.handle(providers, courseID: courseID, vm: vm, actions: actions, reordersCourses: false)
        }
        .accessibilityIdentifier("studio.courses.page")
    }

    private var backButton: some View {
        Button {
            vm.closeCoursePage(in: windowState)
        } label: {
            Label("Courses", systemImage: "chevron.left")
                .zoomedSystemFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.hoverWash)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back to every course")
        .accessibilityIdentifier("studio.courses.back")
    }
}

/// A course page's header: cover, title, where the course comes from, how far
/// the learner is, and the one button that goes on from there. Since
/// 2026-10-06 the progress reads "3 of 10" beside its bar, the lectures and
/// quizzes it counts in its tooltip, and Continue names what it opens in its
/// tooltip rather than in a line beside it.
private struct CoursePageHeader: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    let courseID: String
    let path: CoursePath
    let gate: CourseGate

    var body: some View {
        let entries = path.entries
        // Progress counts what can be done; a lesson sheet with no done
        // state of its own is not waited on (`CourseGate.untrackedEntryIDs`).
        let counted = entries.filter(gate.tracksCompletion)
        let next = gate.nextEntryID.flatMap { id in entries.first { $0.id == id } }
        let lectures = entries.filter { if case .video = $0.kind { return true }; return false }
        let quizzes = entries.filter { $0.quiz != nil }
        let lecturesDone = lectures.filter { gate.state(of: $0) == .finished }.count
        let quizzesCompleted = quizzes.filter { gate.state(of: $0) == .finished }.count
        let started = entries.contains(where: vm.isCoursePathEntryStarted)
        HStack(alignment: .top, spacing: StudioDesign.Spacing.xLarge) {
            CourseCoverImage(artworkURL: vm.courseArtworkURL(courseID))
                .frame(width: 176, height: 99)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
                Text(vm.courseDisplayName(courseID))
                    .zoomedSystemFont(size: 23, weight: .bold)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = vm.courseDisplaySubtitle(courseID) {
                    Text(subtitle)
                        .zoomedSystemFont(size: 13)
                        .foregroundStyle(.secondary)
                }
                CourseNotebooksLine(courseID: courseID)
                if !counted.isEmpty {
                    let finished = counted.filter { gate.state(of: $0) == .finished }.count
                    let parts = [
                        lectures.isEmpty ? nil : "\(lecturesDone) of \(lectures.count) lectures",
                        quizzes.isEmpty ? nil : "\(quizzesCompleted) of \(quizzes.count) quizzes completed",
                    ].compactMap { $0 }
                    HStack(spacing: StudioDesign.Spacing.medium) {
                        CourseProgressBar(
                            fraction: Double(finished) / Double(counted.count),
                            isComplete: next == nil
                        )
                        .frame(width: 160)
                        Text("\(finished) of \(counted.count)")
                            .zoomedSystemFont(size: 12)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .help(parts.joined(separator: " · "))
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(parts.joined(separator: ", "))
                    .accessibilityIdentifier("studio.courses.progress")
                }
                HStack(spacing: StudioDesign.Spacing.medium) {
                    if let next {
                        Button {
                            CoursePathOpening.open(next, courseID: courseID, vm: vm, windowState: windowState)
                        } label: {
                            Label(started ? "Continue" : "Start", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .help(CoursePathOpening.name(of: next, vm: vm, courseID: courseID))
                        .accessibilityIdentifier("studio.courses.continue")
                    } else if !counted.isEmpty {
                        Label("Finished", systemImage: "checkmark.circle.fill")
                            .zoomedSystemFont(size: 13, weight: .medium)
                            .foregroundStyle(.green)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        CourseMenuItems(courseID: courseID)
                    } label: {
                        Image(systemName: "ellipsis")
                            .zoomedSystemFont(size: 13, weight: .semibold)
                            .frame(width: 28, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .hoverHighlight(cornerRadius: 6, inset: 0, opacity: 0.10)
                    .help("Course actions")
                    .accessibilityIdentifier("studio.courses.menu")
                }
            }
        }
    }
}

/// The notebooks that follow a course, on its page: "Linked to <Notebook>",
/// each a click that opens that notebook in this window. A course lives in no
/// notebook, so a course nothing follows says nothing here; Make Study
/// Notebook and Link to Notebook ▸ are in the page's ⋯ (`CourseMenuItems`).
private struct CourseNotebooksLine: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    let courseID: String

    var body: some View {
        let following = vm.notebooksFollowingCourse(courseID)
        if !following.isEmpty {
            HStack(spacing: StudioDesign.Spacing.xSmall) {
                Text("Linked to")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                ForEach(following) { notebook in
                    let title = NotebookTitle(notebook.title)
                    Button {
                        vm.inWindow(windowState) { vm.openNotebook(notebook.id, in: windowState) }
                    } label: {
                        Label {
                            Text(title.text)
                        } icon: {
                            NotebookIconView(notebookID: notebook.id, size: 14, cornerRadius: 3) {
                                Text(title.displayIcon)
                            }
                        }
                        .zoomedSystemFont(size: 12)
                        .lineLimit(1)
                    }
                    .buttonStyle(.hoverWash)
                    .foregroundStyle(.secondary)
                    .help("Open \(title.text)")
                    .opensInOtherWindow(StudioWindowDestination.notebook(notebook.id))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("studio.courses.notebooks")
        }
    }
}

/// A lecture: its number and title, then its rows. Its "2 of 4" shows under
/// the pointer and in grey (2026-10-06): every card carried it, turning green
/// when done, beside rows that each already show their own check.
private struct CourseUnitCard: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(CourseActionsModel.self) private var actions
    let courseID: String
    let unit: CourseUnit
    let gate: CourseGate
    @State private var isHovering = false

    var body: some View {
        let videos = unit.entries.filter { if case .video = $0.kind { return true }; return false }
        let counted = unit.entries.filter(gate.tracksCompletion)
        let finished = counted.filter { gate.state(of: $0) == .finished }.count
        let locked = !unit.entries.isEmpty && unit.entries.allSatisfy { gate.state(of: $0).lockingQuizID != nil }
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: StudioDesign.Spacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LECTURE \(unit.lecture.number)")
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                    Text(unit.title)
                        .zoomedSystemFont(size: 15, weight: .semibold)
                        .foregroundStyle(locked ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: StudioDesign.Spacing.medium)
                if locked {
                    Image(systemName: "lock.fill")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.tertiary)
                        .help(lockHelp)
                } else if !counted.isEmpty {
                    Text("\(finished) of \(counted.count)")
                        .zoomedSystemFont(size: 11)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .opacity(isHovering ? 1 : 0)
                }
            }
            .padding(.horizontal, StudioDesign.Spacing.small)
            .padding(.bottom, StudioDesign.Spacing.xSmall)
            .contentShape(Rectangle())
            .contextMenu { lectureMenu }
            ForEach(unit.entries) { entry in
                CoursePathRow(
                    courseID: courseID,
                    entry: entry,
                    state: gate.state(of: entry),
                    tracksCompletion: gate.tracksCompletion(of: entry),
                    isNext: entry.id == gate.nextEntryID,
                    // One video under the lecture's heading needs no number
                    // of its own; a lecture split across videos keeps "3A)".
                    // The row names the video and the heading names what the
                    // lecture teaches, which may not be the video's title.
                    titleOverride: videos.count == 1 && entry.id == videos.first?.id ? soleVideoTitle(entry) : nil
                )
            }
            if unit.entries.isEmpty {
                Text("Nothing filed under this lecture yet.")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, StudioDesign.Spacing.small)
            }
        }
        .padding(StudioDesign.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        // A group of its own: on a plain container the identifier replaced
        // every lecture row's own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.courses.unit")
    }

    /// The lecture's one video, without the number its heading already shows.
    private func soleVideoTitle(_ entry: CoursePathEntry) -> String? {
        guard case .video(_, let displayTitle) = entry.kind else { return nil }
        let title = StudioViewModel.stripDanglingLectureSeparators(
            StudioViewModel.strippedLeadingLectureOrdinal(displayTitle)
        )
        return title.isEmpty ? unit.title : title
    }

    private var lockHelp: String {
        guard let quizID = unit.entries.first.flatMap({ gate.state(of: $0).lockingQuizID }) else { return "" }
        return "Opens once you complete \(vm.courseQuizDisplayTitle(quizID))"
    }

    @ViewBuilder
    private var lectureMenu: some View {
        let practiceID = CourseQuizPlanning.practiceID(courseID: courseID, lectureID: unit.lecture.id)
        let hasVideo = vm.lectureHasVideo(unit.lecture.id)
        if hasVideo {
            // A lecture's quiz is written from the lecture (product owner,
            // 2026-09-26), never by opening a row for one.
            Button {
                Task { await vm.writeLectureQuiz(courseID: courseID, lectureID: unit.lecture.id) }
            } label: {
                Label(vm.courseQuiz(practiceID) != nil ? "Rewrite Quiz" : "Write Quiz", systemImage: "checklist")
            }
            .disabled(vm.courseQuizWritingProgress[courseID] != nil)
        }
        Button {
            actions.present(.renameLecture(unit.lecture.id), text: unit.lecture.title ?? unit.title)
        } label: {
            Label("Rename Lecture…", systemImage: "pencil")
        }
    }
}

/// A row that says something is under way in the course: quizzes being
/// written, a textbook being planned in.
private struct CourseActivityRow: View {
    let text: String

    var body: some View {
        HStack(spacing: StudioDesign.Spacing.small) {
            ProgressView().controlSize(.small)
            Text(text)
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, StudioDesign.Spacing.small)
    }
}

// MARK: - Rows

/// What a click on a row of the path opens, and what the header's Continue
/// names. A locked row opens nothing: it says which quiz opens it.
enum CoursePathOpening {
    @MainActor
    static func open(_ entry: CoursePathEntry, courseID: String, vm: StudioViewModel, windowState: StudioWindowState) {
        switch entry.kind {
        case .video(let row, _), .material(let row):
            Task { await vm.openCourseSource(row.article.id, in: windowState) }
        case .reading(let reading):
            Task { await vm.openCourseReading(reading, in: windowState) }
        case .quiz(let target, _):
            // Taking a quiz opens a chat (product owner, 2026-09-26): the tutor asks,
            // the learner answers in the composer.
            vm.inWindow(windowState) { vm.takeCourseQuiz(target.quizID) }
        }
    }

    @MainActor
    static func name(of entry: CoursePathEntry, vm: StudioViewModel, courseID: String) -> String {
        switch entry.kind {
        case .video(_, let displayTitle): return displayTitle
        case .material(let row): return vm.courseMaterialDisplayTitle(row.article.title, courseID: courseID)
        case .reading(let reading): return reading.title
        case .quiz(let target, let quiz):
            switch quiz.kind {
            case .practice: return quiz.hasTopicTitle ? "Quiz · \(target.title)" : "Quiz · \(target.subtitle)"
            case .checkpoint: return quiz.hasTopicTitle ? "Checkpoint · \(target.title)" : "\(target.title) · \(target.subtitle)"
            case .test: return target.title
            }
        }
    }
}

/// One row of a course's path: a lecture video, a reading, a material or a
/// quiz, with where it stands at the trailing edge — an open ring, a green
/// check once a source is done, a quiz score ring once its sitting is done,
/// or a lock while a quiz before it is not yet completed. A quiz's ring fills
/// by the fraction right and becomes the green check at a perfect score. Done
/// rows are drawn a little fainter and the row Continue opens has its ring in
/// the accent colour, so the page reads at a glance: what is behind, what is
/// next, what is locked. (Until 2026-10-06 that row was also tinted: one
/// mark says it.)
struct CoursePathRow: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @SyncedStorage(AssistantIntegrationSettings.enabledKey) private var assistantIntegrationsEnabled = true
    let courseID: String
    let entry: CoursePathEntry
    let state: CourseStepState
    /// False for a row with no done state (`CourseGate.untrackedEntryIDs`):
    /// it draws no ring, since nothing would ever fill it.
    var tracksCompletion = true
    /// The row Continue opens.
    var isNext = false
    var titleOverride: String? = nil
    var isMilestone = false

    private var isLocked: Bool { state.lockingQuizID != nil }

    /// Done rows step back a little and locked ones further, while the done
    /// mark and the lock stay at full strength.
    private var contentOpacity: Double {
        switch state {
        case .open: return 1
        case .finished: return 0.62
        case .locked: return 0.45
        }
    }

    var body: some View {
        Button {
            if let quizID = state.lockingQuizID {
                vm.showToast("Opens once you complete \(vm.courseQuizDisplayTitle(quizID)).")
            } else {
                CoursePathOpening.open(entry, courseID: courseID, vm: vm, windowState: windowState)
            }
        } label: {
            HStack(alignment: .center, spacing: StudioDesign.Spacing.medium) {
                HStack(alignment: .center, spacing: StudioDesign.Spacing.medium) {
                    leading
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .zoomedSystemFont(size: 13, weight: isMilestone ? .semibold : .medium)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let detail {
                            Text(detail)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .opacity(contentOpacity)
                Spacer(minLength: StudioDesign.Spacing.small)
                trailing
            }
            .padding(.vertical, 3)
            .padding(.horizontal, StudioDesign.Spacing.small)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
        .onDrag { dragProvider() }
        .contextMenu { menu }
        .help(help)
        .accessibilityIdentifier(accessibilityID)
    }

    // MARK: Content

    private var title: String {
        if let titleOverride { return titleOverride }
        switch entry.kind {
        case .video(_, let displayTitle): return displayTitle
        case .material(let row): return vm.courseMaterialDisplayTitle(row.article.title, courseID: courseID)
        case .reading(let reading): return reading.title
        case .quiz(let target, _): return target.title
        }
    }

    private var detail: String? {
        switch entry.kind {
        case .video(let row, _):
            return videoProgress(row.article)?.displayLabel ?? vm.videoChannelName(for: row.article)
        case .material(let row):
            var parts = [row.article.sourceType == .paper ? "Reading" : row.item.role.label]
            if row.article.sourceType == .paper {
                parts.append(contentsOf: row.article.paperMetadataDisplayParts.prefix(1))
            } else if let author = row.article.author, !author.isEmpty {
                parts.append(author)
            }
            return parts.joined(separator: " · ")
        case .reading(let reading):
            guard let count = reading.pages?.count else { return "Reading" }
            return count == 1 ? "Reading · 1 page" : "Reading · \(count) pages"
        case .quiz(let target, let quiz):
            return quizDetail(target: target, quiz: quiz)
        }
    }

    private func quizDetail(target: CourseQuizTarget, quiz: CourseQuiz) -> String? {
        let score = vm.courseQuizScore(quizID: target.quizID, legacyVideoSourceID: target.legacyVideoSourceID)
        let unfinished = vm.courseQuizSittings[target.quizID].flatMap { $0.isUnderWay ? $0 : nil }
        var parts: [String] = []
        // A named quiz says what kind of quiz it is on its second line, since
        // its title names the topics instead.
        if quiz.hasTopicTitle && quiz.kind != .test {
            parts.append(quiz.kind == .practice ? "Quiz" : "Checkpoint")
        }
        if quiz.kind != .practice { parts.append(target.subtitle) }
        if let unfinished {
            parts.append("In progress · \(unfinished.done) of \(unfinished.total)")
        } else if let score, score.matches(questionCount: quiz.questions.count) {
            // A completed sitting already opened what follows. The tile's
            // seal and this line keep the separate mastery result visible.
            if score.passes {
                parts.append("Passed · \(score.label)")
            } else if score.hasPassed {
                parts.append("Passed earlier · \(score.label)")
            } else {
                parts.append(score.label)
            }
        } else {
            // A quiz rewritten since its last sitting reads like a new one:
            // the old score says nothing about these questions (product owner,
            // 2026-09-28).
            parts.append("\(quiz.questions.count) questions")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var leading: some View {
        switch entry.kind {
        case .video(let row, _):
            CourseVideoThumbnail(article: row.article, progress: videoProgress(row.article))
        case .material(let row):
            SourceThumbnail(source: row.article, size: 36)
                .frame(width: 64, height: 36)
        case .reading:
            let finished = state == .finished
            Image(systemName: finished ? "book.fill" : "book")
                .zoomedSystemFont(size: 15, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 36)
        case .quiz(let target, let quiz):
            CourseQuizTile(quiz: quiz, symbol: quizSymbol(target: target, quiz: quiz), status: quizStatus(target))
                .frame(width: 64, height: 36)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .finished:
            if let quizScore {
                CourseQuizScoreRing(score: quizScore)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .zoomedSystemFont(size: 15)
                    .foregroundStyle(.green)
                    .frame(width: 18)
                    .accessibilityLabel("Done")
            }
        case .locked:
            Image(systemName: "lock.fill")
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.tertiary)
                .frame(width: 18)
                .accessibilityLabel("Locked")
        case .open:
            if let quizScore {
                // A legacy gate may still call a scored row open while its
                // synced score is arriving. The mastery mark wins either way.
                CourseQuizScoreRing(score: quizScore)
            } else if tracksCompletion {
                Image(systemName: "circle")
                    .zoomedSystemFont(size: 15)
                    .foregroundStyle(isNext ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    .frame(width: 18)
                    .accessibilityLabel(isNext ? "Next" : "Not done")
            } else {
                Color.clear
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
        }
    }

    private var quizScore: LectureQuizScore? {
        guard case .quiz(let target, _) = entry.kind else { return nil }
        return vm.courseQuizScore(quizID: target.quizID, legacyVideoSourceID: target.legacyVideoSourceID)
    }

    private func videoProgress(_ article: StudioArticle) -> VideoWatchProgress? {
        vm.readingProgressStore.videoWatchProgress(for: article.id, fallbackLocator: article.readingPositionLocator)
    }

    private func quizSymbol(target: CourseQuizTarget, quiz: CourseQuiz) -> String {
        let scored = vm.courseQuizScore(quizID: target.quizID, legacyVideoSourceID: target.legacyVideoSourceID) != nil
        var symbol: String
        switch quiz.kind {
        case .practice: symbol = scored ? "checklist.checked" : "checklist"
        case .checkpoint: symbol = "flag"
        case .test: symbol = "flag.checkered"
        }
        // The writer's symbol for the topics, unless it is the plain glyph
        // (which keeps its checked state) or one this Mac does not draw.
        if let chosen = quiz.symbol, chosen != CourseQuizGeneratorService.fallbackSymbol(for: quiz.kind),
           NSImage(systemSymbolName: chosen, accessibilityDescription: nil) != nil {
            symbol = chosen
        }
        return symbol
    }

    /// A lecture's thumbnail carries its watched bar; a quiz's tile carries
    /// the sitting under way the same way, and a done quiz a seal coloured by
    /// its score (product owner, 2026-09-27).
    private func quizStatus(_ target: CourseQuizTarget) -> CourseQuizTileStatus? {
        if let unfinished = vm.courseQuizSittings[target.quizID], unfinished.isUnderWay, unfinished.total > 0 {
            return .underWay(Double(unfinished.done) / Double(unfinished.total))
        }
        if let score = vm.courseQuizScore(quizID: target.quizID, legacyVideoSourceID: target.legacyVideoSourceID) {
            return .done(right: score.right, total: score.total)
        }
        return nil
    }

    private var help: String {
        if let quizID = state.lockingQuizID {
            return "Opens once you complete \(vm.courseQuizDisplayTitle(quizID))"
        }
        switch entry.kind {
        case .reading(let reading): return vm.textbookReadingHelp(reading)
        case .quiz(_, let quiz): return quiz.kind == .practice ? "Quiz yourself on this lecture" : "Quiz yourself on what came before"
        default: return "Open beside the course"
        }
    }

    private var accessibilityID: String {
        switch entry.kind {
        case .quiz(let target, _): return "course-quiz-\(target.quizID)"
        case .reading(let reading): return "course-reading-\(reading.id)"
        case .video(let row, _), .material(let row): return "course-item-\(row.article.id)"
        }
    }

    private func dragProvider() -> NSItemProvider {
        guard !isLocked, let sourceID = entry.sourceID, let article = vm.articlesById[sourceID] else {
            return NSItemProvider()
        }
        StudioDragVisibility.shared.begin(articleIDs: [sourceID])
        return articleDragProvider(for: article, selectedArticleIds: [sourceID])
    }

    // MARK: Menu

    @ViewBuilder
    private var menu: some View {
        switch entry.kind {
        case .video(let row, _):
            sourceItems(row.article)
            Divider()
            let practiceID = CourseQuizPlanning.practiceID(courseID: courseID, lectureID: row.lecture.id)
            Button {
                Task { await vm.writeLectureQuiz(courseID: courseID, lectureID: row.lecture.id) }
            } label: {
                Label(vm.courseQuiz(practiceID) != nil ? "Rewrite Quiz" : "Write Quiz", systemImage: "checklist")
            }
            .disabled(vm.courseQuizWritingProgress[courseID] != nil)
            LectureVideoPapersMenu(lectureID: row.lecture.id)
            Divider()
            removeItem(row.item.id)
        case .material(let row):
            sourceItems(row.article)
            // An assigned reading on a lecture with a video can be turned back
            // into one of the video's cited papers, off the path.
            if row.article.sourceType == .paper, row.item.role == .reading, vm.lectureHasVideo(row.lecture.id) {
                Divider()
                Button {
                    Task { await vm.setLectureItemRole(row.item.id, to: .reference) }
                } label: {
                    Label("Only Cited, Not Assigned Reading", systemImage: "quote.bubble")
                }
            }
            Divider()
            removeItem(row.item.id)
        case .reading(let reading):
            Button {
                Task { await vm.openCourseReading(reading, in: windowState) }
            } label: {
                Label("Open Reading", systemImage: "book")
            }
            .disabled(isLocked)
            Divider()
            Button(role: .destructive) {
                Task { await vm.removeLectureItem(reading.item.id) }
            } label: {
                Label("Remove Reading", systemImage: "trash")
            }
        case .quiz(let target, let quiz):
            quizItems(target: target, quiz: quiz)
        }
    }

    @ViewBuilder
    private func sourceItems(_ article: StudioArticle) -> some View {
        Button {
            Task { await vm.openCourseSource(article.id, in: windowState) }
        } label: {
            Label("Open", systemImage: "doc.text")
        }
        .disabled(isLocked)
        if !isLocked {
            OtherWindowSourceMenuItem(article)
            if vm.sidebarTab(listing: article) != nil {
                Button {
                    vm.showCourseSourceInSources(article, in: windowState)
                } label: {
                    Label("Show in Sources", systemImage: "sidebar.right")
                }
            }
            // The row's check says watched; its menu can undo it. A locked
            // row is unfinished by definition, and marking it watched would
            // skip the gate.
            VideoWatchedMenuItems(article: article)
        }
        if assistantIntegrationsEnabled {
            Button {
                vm.addSourcesToContext([article.id])
            } label: {
                Label("Add to MCP Context", systemImage: "sparkles")
            }
        }
    }

    private func removeItem(_ itemID: String) -> some View {
        Button {
            Task { await vm.removeLectureItem(itemID) }
        } label: {
            Label("Remove from Course", systemImage: "minus.circle")
        }
    }

    @ViewBuilder
    private func quizItems(target: CourseQuizTarget, quiz: CourseQuiz) -> some View {
        let unfinished = vm.courseQuizSittings[target.quizID].flatMap { $0.isUnderWay ? $0 : nil }
        let hasResults = vm.courseQuizFinishedSittings[target.quizID] != nil
        let drawing = vm.courseQuizDrawingIDs.contains(target.quizID)
        Button {
            vm.inWindow(windowState) { vm.takeCourseQuiz(target.quizID) }
        } label: {
            if unfinished != nil {
                Label("Continue Quiz", systemImage: "play")
            } else if hasResults {
                Label("See Results", systemImage: "list.bullet.clipboard")
            } else {
                Label("Take Quiz", systemImage: "play")
            }
        }
        .disabled(isLocked)
        if (unfinished != nil || hasResults) && !isLocked {
            Button {
                vm.inWindow(windowState) { vm.takeCourseQuiz(target.quizID, startOver: true) }
            } label: {
                Label(unfinished == nil ? "Retake Quiz" : "Start Over", systemImage: "arrow.counterclockwise")
            }
        }
        Divider()
        Button {
            Task { await vm.drawCourseQuizPicture(quiz.id) }
        } label: {
            Label(quiz.artwork == nil ? "Draw Picture" : "Redraw Picture", systemImage: "paintbrush")
        }
        .disabled(drawing)
        if quiz.artwork != nil {
            Button {
                Task { await vm.removeCourseQuizPicture(quiz.id) }
            } label: {
                Label("Remove Picture", systemImage: "photo.badge.minus")
            }
            .disabled(drawing)
        }
        Button {
            Task { await vm.addPicturesToCourseQuizzes(courseID: quiz.courseID, only: [quiz.id]) }
        } label: {
            Label("Add Pictures to Questions", systemImage: "rectangle.on.rectangle")
        }
        .disabled(drawing)
        Divider()
        Button(role: .destructive) {
            Task { await vm.deleteCourseQuiz(quiz.id) }
        } label: {
            Label("Remove Quiz", systemImage: "trash")
        }
    }
}

/// The course row's compact mastery mark: the existing open ring fills
/// clockwise with answers right, then becomes the standard green done check
/// only when every answer is right.
private struct CourseQuizScoreRing: View {
    let score: LectureQuizScore

    var body: some View {
        Group {
            if score.isFullyRight {
                Image(systemName: "checkmark.circle.fill")
                    .zoomedSystemFont(size: 15)
                    .foregroundStyle(.green)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.14), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: score.fractionRight)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 15, height: 15)
                .animation(.easeInOut(duration: 0.2), value: score.right)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(score.right) of \(score.total) quiz questions right")
        .help(score.label)
    }
}

/// Course material no lecture claims, closing the page: open, never gated.
private struct CourseLooseMaterialRow: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    let courseID: String
    let article: StudioArticle

    var body: some View {
        Button {
            Task { await vm.openCourseSource(article.id, in: windowState) }
        } label: {
            HStack(spacing: StudioDesign.Spacing.medium) {
                SourceThumbnail(source: article, size: 36)
                    .frame(width: 64, height: 36)
                Text(vm.courseMaterialDisplayTitle(article.title, courseID: courseID))
                    .zoomedSystemFont(size: 13, weight: .medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, StudioDesign.Spacing.small)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
        .onDrag {
            StudioDragVisibility.shared.begin(articleIDs: [article.id])
            return articleDragProvider(for: article, selectedArticleIds: [article.id])
        }
        .contextMenu {
            Button {
                Task { await vm.openCourseSource(article.id, in: windowState) }
            } label: {
                Label("Open", systemImage: "doc.text")
            }
            OtherWindowSourceMenuItem(article)
            if vm.sidebarTab(listing: article) != nil {
                Button {
                    vm.showCourseSourceInSources(article, in: windowState)
                } label: {
                    Label("Show in Sources", systemImage: "sidebar.right")
                }
            }
            Divider()
            Button {
                Task { await vm.removeArticleFromCourse(articleId: article.id) }
            } label: {
                Label("Remove from Course", systemImage: "minus.circle")
            }
        }
        .help("Open beside the course")
        .accessibilityIdentifier("course-item-\(article.id)")
    }
}

/// A lecture video's cited papers, which have no row in the course's path:
/// each opens in the reader, becomes assigned reading, or comes off the
/// lecture (product owner, 2026-09-27: "those attached papers should just be shown
/// maybe upon right click on the video").
struct LectureVideoPapersMenu: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    let lectureID: String

    var body: some View {
        let papers = vm.lectureVideoPapers(for: lectureID)
        if !papers.isEmpty {
            Menu {
                ForEach(papers, id: \.item.id) { paper in
                    Menu(vm.displayTitle(for: paper.article)) {
                        Button {
                            Task { await vm.openCourseSource(paper.article.id, in: windowState) }
                        } label: {
                            Label("Open", systemImage: "doc.text")
                        }
                        Button {
                            Task { await vm.setLectureItemRole(paper.item.id, to: .reading) }
                        } label: {
                            Label("Assign as Reading", systemImage: "book")
                        }
                        Button {
                            Task { await vm.removeLectureItem(paper.item.id) }
                        } label: {
                            Label("Remove from Lecture", systemImage: "minus.circle")
                        }
                    }
                }
            } label: {
                Label("Papers (\(papers.count))", systemImage: "doc.text.magnifyingglass")
            }
        }
    }
}

// MARK: - A course's notebooks

/// What a course offers about notebooks: **Make Study Notebook**, a notebook
/// named after it that holds its sources and follows it (**Open Study
/// Notebook** once it exists), **Link to Notebook ▸**, which makes a notebook
/// follow the course, and **Unlink from <Notebook>**. None of it moves the
/// course: it lives in no notebook.
private struct CourseNotebookMenuItems: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    let courseID: String
    /// What the suggestions are read from: the course's sources.
    let sourceIDs: [String]

    var body: some View {
        if !vm.isActiveLibraryReadOnly {
            let following = vm.notebooksFollowingCourse(courseID)
            let followingIDs = Set(following.map(\.id))
            let studyID = TeamContentIdentity.courseNotebookID(courseID: courseID)
            let hasStudyNotebook = vm.notebooks.contains { $0.id == studyID }
            let choices = vm.notebookChoices(forSourceIDs: sourceIDs, livesIn: followingIDs)
            let suggested = choices.filter(\.isSuggested)
            let rest = choices.filter { !$0.isSuggested }
            Button {
                Task { await vm.makeStudyNotebook(forCourse: courseID, in: windowState) }
            } label: {
                Label(hasStudyNotebook ? "Open Study Notebook" : "Make Study Notebook", systemImage: "book.closed")
            }
            Menu {
                if !suggested.isEmpty {
                    Section("Suggested") {
                        ForEach(suggested) { choice in
                            Button(NotebookTitle(choice.title).text) {
                                Task { await vm.followCourseFromMenu(courseID, inNotebook: choice.notebookID) }
                            }
                        }
                    }
                }
                if !suggested.isEmpty, !rest.isEmpty { Divider() }
                ForEach(rest) { choice in
                    Button(NotebookTitle(choice.title).text) {
                        Task { await vm.followCourseFromMenu(courseID, inNotebook: choice.notebookID) }
                    }
                }
            } label: {
                Label("Link to Notebook", systemImage: "link")
            }
            .disabled(choices.isEmpty)
            ForEach(following) { notebook in
                Button {
                    Task { await vm.unfollowCourseFromMenu(courseID, inNotebook: notebook.id) }
                } label: {
                    Label("Unlink from \(NotebookTitle(notebook.title).text)", systemImage: "link.badge.minus")
                }
            }
        }
    }
}

// MARK: - Course menu

/// The whole-course actions: the course page's ⋯ menu and a card's context
/// menu. Since 2026-10-06 grouped (the product owner: "cleaner and fewer buttons"):
/// the quiz actions under **Quizzes ▸**, the lectures' under **Lectures ▸**,
/// instructors, course code and institution under **Edit Details ▸**, every
/// item under the name it had when the menu was one list of twenty-odd.
struct CourseMenuItems: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(CourseActionsModel.self) private var actions
    @SyncedStorage(AssistantIntegrationSettings.enabledKey) private var assistantIntegrationsEnabled = true
    let courseID: String

    var body: some View {
        let quizzes = vm.courseQuizzes(for: courseID)
        let writing = vm.courseQuizWritingProgress[courseID] != nil
        let metadata = vm.courseMetadata[courseID]
        let itemCount = vm.courseLectures(for: courseID).flatMap { vm.courseLectureItems(for: $0.id) }.count
        let isReadOnlyTeamCourse = vm.courseTeam(courseID).map { !$0.canEdit } ?? false
        if assistantIntegrationsEnabled {
            Button {
                vm.addSourcesToContext(vm.coursePath(for: courseID).entries.compactMap(\.sourceID))
            } label: {
                Label("Add All to MCP Context", systemImage: "sparkles")
            }
        }
        let courseSourceIDs = Set(vm.coursePath(for: courseID).entries.compactMap(\.sourceID))
        let sessionCount = vm.reviewSessionLinks.filter { !Set($0.sourceIDs).isDisjoint(with: courseSourceIDs) }.count
        Button {
            vm.showReviewSessionsForGroup(courseID)
        } label: {
            Label(sessionCount > 0 ? "Show Review Sessions (\(sessionCount))" : "Show Review Sessions",
                  systemImage: "brain.head.profile")
        }
        Divider()
        // A course lives in no notebook; a notebook may follow it.
        CourseNotebookMenuItems(courseID: courseID, sourceIDs: Array(courseSourceIDs))
            .disabled(isReadOnlyTeamCourse)
        Divider()
        // A read-only team's course is read, not changed.
        Group {
            Menu {
                // The Khan ladder, written ahead of time (docs/lecture-quiz-design.md).
                Button {
                    Task { await vm.writeCourseQuizzes(courseID: courseID) }
                } label: {
                    Label(quizzes.isEmpty ? "Write Quizzes" : "Write Missing Quizzes", systemImage: "checklist")
                }
                .disabled(writing)
                if !quizzes.isEmpty {
                    Button {
                        Task { await vm.writeCourseQuizzes(courseID: courseID, rewrite: true) }
                    } label: {
                        Label("Rewrite All Quizzes", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(writing)
                    // A picture for each quiz's tile, drawn only when asked: each is
                    // one image request.
                    if quizzes.contains(where: { $0.artwork == nil }) {
                        Button {
                            Task { await vm.drawCourseQuizPictures(courseID: courseID) }
                        } label: {
                            Label("Draw Quiz Pictures", systemImage: "paintbrush")
                        }
                        .disabled(quizzes.allSatisfy { vm.courseQuizDrawingIDs.contains($0.id) || $0.artwork != nil })
                    }
                    // Pictures for the questions of the quizzes already written:
                    // lecture slides (each video's captured first), reading figures,
                    // and drawings where neither shows the point; the questions
                    // stay as they are.
                    Button {
                        Task { await vm.addPicturesToCourseQuizzes(courseID: courseID) }
                    } label: {
                        Label("Add Pictures to Quiz Questions", systemImage: "rectangle.on.rectangle")
                    }
                    .disabled(quizzes.allSatisfy { vm.courseQuizDrawingIDs.contains($0.id) })
                }
            } label: {
                Label("Quizzes", systemImage: "checklist")
            }
            Menu {
                Button {
                    Task { _ = await vm.createLecture(in: courseID) }
                } label: {
                    Label("Add Lecture", systemImage: "plus.rectangle.on.rectangle")
                }
                Button {
                    actions.present(.addPlaylist(courseID))
                } label: {
                    Label("Add YouTube Playlist…", systemImage: "play.rectangle")
                }
                if let playlistURL = metadata?.playlistURL {
                    Button {
                        Task { await vm.importYouTubePlaylist(url: playlistURL, intoCourse: courseID) }
                    } label: {
                        Label("Refresh Playlist", systemImage: "arrow.clockwise")
                    }
                }
                // Targeted readings from a library book, chosen for this learner
                // (docs/textbook-readings-design.md).
                Button {
                    actions.textbookTarget = TextbookSheetTarget(courseID: courseID, bookID: nil)
                } label: {
                    Label("Add Textbook…", systemImage: "book")
                }
                .disabled(vm.textbookReadingStages[courseID] != nil || vm.courseLectures(for: courseID).isEmpty)
                Divider()
                // Each lecture named for what it teaches, from its transcript;
                // a video title that already says so stays.
                Button {
                    Task { await vm.retitleCourseLectures(courseID: courseID) }
                } label: {
                    Label("Retitle Lectures from Content", systemImage: "text.badge.star")
                }
                .disabled(vm.courseLectureNamingIDs.contains(courseID) || !vm.courseLectures(for: courseID).contains { vm.lectureHasVideo($0.id) })
                Button {
                    Task { await vm.organizeCourse(name: courseID) }
                } label: {
                    Label("Organize", systemImage: "sparkles")
                }
                .disabled(vm.organizingCourseNames.contains(courseID) || itemCount < 2)
            } label: {
                Label("Lectures", systemImage: "rectangle.stack")
            }
            Divider()
            Button {
                actions.present(.rename(courseID), text: vm.courseDisplayName(courseID))
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Menu {
                Button {
                    actions.present(.instructors(courseID), text: metadata?.instructors ?? "")
                } label: {
                    Label(metadata?.instructors != nil ? "Edit Instructor(s)…" : "Add Instructor(s)…", systemImage: "person")
                }
                Button {
                    actions.present(.courseCode(courseID), text: metadata?.courseCode ?? "")
                } label: {
                    Label(metadata?.courseCode != nil ? "Edit Course Code…" : "Add Course Code…", systemImage: "number")
                }
                Button {
                    actions.present(.institution(courseID), text: metadata?.institution ?? "")
                } label: {
                    Label(metadata?.institution != nil ? "Edit Institution…" : "Add Institution…", systemImage: "building.columns")
                }
            } label: {
                Label("Edit Details", systemImage: "info.circle")
            }
        }
        .disabled(isReadOnlyTeamCourse)
        // Sharing goes from the learner's own course into a team, whichever
        // library is open (docs/teams-design.md, decision 21).
        if vm.courseTeamIDs[courseID] == nil {
            ShareWithTeamMenu(precededByDivider: true, offeredInTeamLibrary: true) { teamID in
                Task { await vm.shareCourse(courseID, withTeam: teamID) }
            }
        }
        Divider()
        // Hiding is the member's own, even in a read-only team.
        Button {
            Task { await vm.setCourseHidden(courseID, hidden: true) }
        } label: {
            Label("Hide Course", systemImage: "eye.slash")
        }
        Button(role: .destructive) {
            actions.present(.remove(courseID))
        } label: {
            Label("Remove Course…", systemImage: "trash")
        }
        .disabled(isReadOnlyTeamCourse)
    }
}

// MARK: - Drops

/// What dropping on a course does: sources join it, a book is read along
/// with it (Add Textbook, with the book chosen), a Books-tab group or playlist
/// adds its sources, and on the home another course's card takes this one's
/// place.
enum CourseDropHandler {
    static let types: [UTType] = [.studioArticle, .studioGroup]

    @MainActor
    static func handle(
        _ providers: [NSItemProvider],
        courseID: String,
        vm: StudioViewModel,
        actions: CourseActionsModel,
        reordersCourses: Bool
    ) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.studioGroup.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioGroup.identifier) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(StudioGroupTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        guard transfer.groupName != courseID else { return }
                        if vm.allCourseGroupNames.contains(transfer.groupName) {
                            if reordersCourses { vm.reorderCourse(from: transfer.groupName, to: courseID) }
                        } else if !vm.bookSourceArticles(for: transfer.groupName).isEmpty,
                                  !vm.courseLectures(for: courseID).isEmpty {
                            // A book dropped on a course is read along with it:
                            // targeted readings after their lectures, not every
                            // chapter as material.
                            actions.textbookTarget = TextbookSheetTarget(courseID: courseID, bookID: transfer.groupName)
                        } else {
                            for id in vm.sourceIDsForGroupInOrder(transfer.groupName) {
                                await vm.addArticleToCourse(articleId: id, courseName: courseID)
                            }
                        }
                    }
                }
                handled = true
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.studioArticle.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioArticle.identifier) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(StudioArticleTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        for id in transfer.draggedSourceIDs {
                            await vm.addArticleToCourse(articleId: id, courseName: courseID)
                        }
                    }
                }
                handled = true
            }
        }
        return handled
    }
}

// MARK: - Alerts

/// The alerts and sheets behind a course's menus and the home's New Course.
struct CourseAlerts: ViewModifier {
    let vm: StudioViewModel
    @Bindable var actions: CourseActionsModel

    private func isPresenting(_ matches: @escaping (CourseActionsModel.Alert) -> Bool) -> Binding<Bool> {
        Binding(
            get: { actions.alert.map(matches) ?? false },
            set: { if !$0 { actions.alert = nil } }
        )
    }

    func body(content: Content) -> some View {
        let subject = actions.alert?.subject
        content
            .sheet(isPresented: isPresenting { $0 == .createCourse }) {
                NewCourseSheet(vm: vm)
            }
            .sheet(item: $actions.textbookTarget) { target in
                AddTextbookSheet(vm: vm, target: target)
            }
            .alert("Add YouTube Playlist", isPresented: isPresenting { if case .addPlaylist = $0 { return true }; return false }) {
                TextField("Playlist URL", text: $actions.alertText)
                Button("Cancel", role: .cancel) { }
                Button("Add") {
                    let url = actions.alertText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let subject, !url.isEmpty {
                        Task { await vm.importYouTubePlaylist(url: url, intoCourse: subject) }
                    }
                }
            } message: {
                Text("Paste a YouTube playlist URL. Each lecture will be added to this course.")
            }
            .alert("Remove Course", isPresented: isPresenting { if case .remove = $0 { return true }; return false }) {
                Button("Remove", role: .destructive) {
                    if let subject {
                        Task { await vm.removeCourse(name: subject) }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                let name = subject.map { vm.courseDisplayName($0) } ?? "this course"
                Text("Remove \"\(name)\"? You can undo immediately after removal.")
            }
            .alert("Rename Course", isPresented: isPresenting { if case .rename = $0 { return true }; return false }) {
                TextField("Course title", text: $actions.alertText)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let subject {
                        let value = actions.alertText.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await vm.updateCourseMetadata(groupName: subject) { $0.title = value.isEmpty ? nil : value } }
                    }
                }
            } message: {
                Text("Enter a display title for this course.")
            }
            .alert("Rename Lecture", isPresented: isPresenting { if case .renameLecture = $0 { return true }; return false }) {
                TextField("Lecture title", text: $actions.alertText)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let subject {
                        let value = actions.alertText.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await vm.renameCourseLecture(subject, title: value.isEmpty ? nil : value) }
                    }
                }
            } message: {
                Text("Enter a display title for this lecture.")
            }
            .alert("Instructor(s)", isPresented: isPresenting { if case .instructors = $0 { return true }; return false }) {
                TextField("e.g. Andrew Ng, Fei-Fei Li", text: $actions.alertText)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let subject {
                        let value = actions.alertText.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await vm.updateCourseMetadata(groupName: subject) { $0.instructors = value.isEmpty ? nil : value } }
                    }
                }
            } message: {
                Text("Enter the instructor name(s) for this course.")
            }
            .alert("Course Code", isPresented: isPresenting { if case .courseCode = $0 { return true }; return false }) {
                TextField("e.g. CS229, MIT 6.006", text: $actions.alertText)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let subject {
                        let value = actions.alertText.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await vm.updateCourseMetadata(groupName: subject) { $0.courseCode = value.isEmpty ? nil : value } }
                    }
                }
            } message: {
                Text("Enter the course code.")
            }
            .alert("Institution", isPresented: isPresenting { if case .institution = $0 { return true }; return false }) {
                TextField("e.g. Stanford, MIT", text: $actions.alertText)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let subject {
                        let value = actions.alertText.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await vm.updateCourseMetadata(groupName: subject) { $0.institution = value.isEmpty ? nil : value } }
                    }
                }
            } message: {
                Text("Enter the institution name.")
            }
    }
}

/// A new course is a YouTube playlist: the sheet takes a playlist URL and
/// imports every video as a lecture. Course metadata (title, code, instructor,
/// institution) is edited afterwards from the course's menu.
struct NewCourseSheet: View {
    var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var playlistURL = ""
    @FocusState private var isPlaylistURLFocused: Bool

    private var canImport: Bool {
        YouTubePlaylistService.isPlaylistURL(playlistURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("New Course").font(.headline)
                Spacer()
                Button("Import") { importPlaylist() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("YouTube Playlist URL")
                    .font(.callout.weight(.medium))
                TextField("https://www.youtube.com/playlist?list=…", text: $playlistURL)
                    .textFieldStyle(.roundedBorder)
                    .focused($isPlaylistURLFocused)
                    .accessibilityIdentifier("newCoursePlaylistURLField")
                    .onSubmit {
                        if canImport {
                            importPlaylist()
                        }
                    }
                Text("Each video becomes a lecture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 190)
        .onAppear {
            isPlaylistURLFocused = true
        }
    }

    private func importPlaylist() {
        let url = playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard YouTubePlaylistService.isPlaylistURL(url) else { return }
        Task { await vm.importYouTubePlaylist(url: url) }
        dismiss()
    }
}

// MARK: - Pieces

/// A course's cover: its first lecture video's thumbnail, the cover YouTube
/// uses for the playlist, or a graduation cap on an indigo wash.
struct CourseCoverImage: View {
    let artworkURL: String?

    var body: some View {
        ZStack {
            Color.indigo.opacity(0.10)
            if let artworkURL, let url = URL(string: artworkURL) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipped()
    }

    private var placeholder: some View {
        Image(systemName: "graduationcap")
            .zoomedSystemFont(size: 20)
            .foregroundStyle(.indigo)
    }
}

/// A lecture video's 16:9 thumbnail with the watched sliver along its bottom.
private struct CourseVideoThumbnail: View {
    let article: StudioArticle
    let progress: VideoWatchProgress?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
            if let url = SourceArtwork.remoteURL(for: article) {
                CachedAsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.red)
                    }
                }
            } else {
                Image(systemName: "play.rectangle")
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottom) {
            if let fraction = progress?.fractionWatched, fraction > 0.01 {
                VideoWatchProgressBar(fraction: fraction)
            }
        }
    }
}

/// A course's or lecture's progress as a slim bar, green once finished.
struct CourseProgressBar: View {
    let fraction: Double
    var isComplete = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(isComplete ? Color.green : Color.accentColor)
                    .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityValue("\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent")
    }
}

/// Where a quiz stands, for its tile: a sitting under way (the share of
/// questions graded) or done with a score.
enum CourseQuizTileStatus: Equatable {
    case underWay(Double)
    case done(right: Int, total: Int)
}

/// The quiz's tile where a lecture's thumbnail sits: its drawn picture, else
/// its symbol on an indigo wash, with a spinner while drawing, the progress
/// bar of a sitting under way, and a seal once done.
struct CourseQuizTile: View {
    @Environment(StudioViewModel.self) private var vm
    let quiz: CourseQuiz
    let symbol: String
    let status: CourseQuizTileStatus?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let drawing = vm.courseQuizDrawingIDs.contains(quiz.id)
        ZStack {
            if let image = Self.artworkImage(quiz) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(shape)
            } else {
                shape
                    .fill(Color.indigo.opacity(0.10))
                    .overlay(
                        Image(systemName: symbol)
                            .zoomedSystemFont(size: 15, weight: .semibold)
                            .foregroundStyle(.indigo)
                    )
            }
            if drawing {
                shape.fill(.black.opacity(0.25))
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 36, height: 36)
        .overlay(alignment: .bottom) {
            if case .underWay(let fraction)? = status {
                VideoWatchProgressBar(fraction: max(fraction, 0.08))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if case .done(let right, let total)? = status {
                CourseQuizDoneSeal(right: right, total: total)
                    .offset(x: 5, y: 5)
            }
        }
    }

    /// Decoded quiz pictures, so a redraw of the page does not decode every
    /// tile's JPEG again. Keyed by quiz and version; a redraw bumps
    /// `updatedAt`, so the old picture is never shown for the new one.
    private static let artworkCache = NSCache<NSString, NSImage>()

    private static func artworkImage(_ quiz: CourseQuiz) -> NSImage? {
        guard let artwork = quiz.artwork else { return nil }
        let key = "\(quiz.id)|\(quiz.updatedAt.timeIntervalSinceReferenceDate)|\(artwork.count)" as NSString
        if let cached = artworkCache.object(forKey: key) { return cached }
        guard let image = NSImage(data: artwork) else { return nil }
        artworkCache.setObject(image, forKey: key)
        return image
    }
}

/// The seal on a done quiz's tile: green when every answer was right, orange
/// when some were, red when none were — done either way, and the score says
/// how it went.
private struct CourseQuizDoneSeal: View {
    let right: Int
    let total: Int

    private var color: Color {
        if total > 0, right >= total { return .green }
        return right > 0 ? .orange : .red
    }

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .zoomedSystemFont(size: 13, weight: .semibold)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, color)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1.5))
            .help("Done · \(right) of \(total) right")
            .accessibilityLabel("Done, \(right) of \(total) right")
            .accessibilityIdentifier("studio.courses.quizDone")
    }
}
