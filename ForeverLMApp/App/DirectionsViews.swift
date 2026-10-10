import AppKit
import SwiftUI

// MARK: - Directions (docs/directions-design.md)
//
// What a Goal or Idea shows of the Directions proposed toward it: a chip on
// its row that says how many there are and how many wait for an answer, and
// the list it opens — one card per Direction, with the evidence it rests on,
// the case against it, the cheapest test, and the learner's answer. Nothing
// here asks a model anything; **Find directions** hands the search to a Deep
// Research chat (`StudioViewModel.requestDirectionSearch`).

/// The row's chip: "3 directions · 2 new". Drawn only when the home has any,
/// so a Goal nobody searched for is not nagged.
struct DirectionsChip: View {
    @Environment(StudioViewModel.self) private var vm
    let homeKind: DirectionHomeKind
    let homeID: String
    let homeTitle: String
    /// Starts another search from the list's **Find more**.
    let findMore: () -> Void
    @State private var isListing = false

    var body: some View {
        let counts = vm.researchDirectionCounts(forHome: homeID)
        let all = vm.researchDirections(forHome: homeID).count
        if all > 0 {
            Button {
                isListing.toggle()
            } label: {
                Label(DirectionListing.chipText(open: counts.open, waiting: counts.waiting, all: all), systemImage: "signpost.right")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(counts.waiting > 0 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.hoverWash)
            .help(counts.waiting > 0 ? "Directions waiting for your answer" : "The directions found for this \(homeKind.noun)")
            .accessibilityIdentifier("studio.directions.chip")
            .popover(isPresented: $isListing, arrowEdge: .bottom) {
                DirectionsPopover(homeKind: homeKind, homeID: homeID, homeTitle: homeTitle) {
                    isListing = false
                    findMore()
                } dismiss: {
                    isListing = false
                }
            }
        }
    }
}

enum DirectionListing {
    /// "3 directions · 2 new"; "1 set aside" when every one was set aside.
    static func chipText(open: Int, waiting: Int, all: Int) -> String {
        guard open > 0 else { return all == 1 ? "1 set aside" : "\(all) set aside" }
        let head = open == 1 ? "1 direction" : "\(open) directions"
        return waiting > 0 ? "\(head) · \(waiting) new" : head
    }

    /// The quick reasons Set aside offers; the learner's own words are one
    /// more choice. The next search reads whichever was given.
    static let setAsideReasons = [
        "Already knew about it",
        "Not convinced by the evidence",
        "Not what I'm after",
        "Too far from anything I can do",
    ]
}

/// The list a Directions chip opens: pursued first, then the proposals
/// waiting for an answer, then what was set aside, folded.
struct DirectionsPopover: View {
    @Environment(StudioViewModel.self) private var vm
    let homeKind: DirectionHomeKind
    let homeID: String
    let homeTitle: String
    let findMore: () -> Void
    let dismiss: () -> Void
    @State private var isShowingSetAside = false

    var body: some View {
        let directions = vm.researchDirections(forHome: homeID)
        let pursued = directions.filter(\.isPursued)
        let proposed = directions.filter(\.isProposed)
        let setAside = directions.filter(\.isSetAside)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Directions")
                        .zoomedSystemFont(size: 13, weight: .semibold)
                    Text(homeTitle)
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: StudioDesign.Spacing.medium)
                Button {
                    findMore()
                } label: {
                    Label("Find more", systemImage: "magnifyingglass")
                        .zoomedSystemFont(size: 12)
                }
                .buttonStyle(.hoverWash)
                .help("Search again: the literature and the web, starting from your answers so far")
                .accessibilityIdentifier("studio.directions.findMore")
            }
            .padding(.horizontal, StudioDesign.Spacing.medium)
            .padding(.top, StudioDesign.Spacing.medium)
            .padding(.bottom, StudioDesign.Spacing.small)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: StudioDesign.Spacing.medium) {
                    if !pursued.isEmpty {
                        section("Pursuing", pursued)
                    }
                    if !proposed.isEmpty {
                        section(proposed.count == 1 ? "Waiting for your answer" : "\(proposed.count) waiting for your answer", proposed)
                    }
                    if !setAside.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { isShowingSetAside.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .zoomedSystemFont(size: 9, weight: .semibold)
                                    .rotationEffect(.degrees(isShowingSetAside ? 90 : 0))
                                Text("\(setAside.count) set aside")
                                    .zoomedSystemFont(size: 11, weight: .semibold)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.hoverWash)
                        .accessibilityIdentifier("studio.directions.setAsideToggle")
                        if isShowingSetAside {
                            ForEach(setAside) { direction in
                                DirectionCard(direction: direction, dismiss: dismiss)
                            }
                        }
                    }
                }
                .padding(StudioDesign.Spacing.medium)
            }
            .frame(maxHeight: 560)
        }
        .frame(width: 480)
        // A group of its own: on a plain container the identifier landed on
        // the heading, Find more (in place of its own) and the scroll area.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.directions.list")
    }

    @ViewBuilder
    private func section(_ title: String, _ directions: [ResearchDirection]) -> some View {
        Text(title)
            .zoomedSystemFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
        ForEach(directions) { direction in
            DirectionCard(direction: direction, dismiss: dismiss)
        }
    }
}

/// One Direction: its angle, its sentence and why it is worth a look, then —
/// opened — the evidence, the case against it and the cheapest test; and the
/// answers the learner can give it.
struct DirectionCard: View {
    @Environment(StudioViewModel.self) private var vm
    let direction: ResearchDirection
    let dismiss: () -> Void
    @State private var isExpanded = false
    @State private var isWritingReason = false
    @State private var reason = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
            HStack(spacing: StudioDesign.Spacing.xSmall) {
                Label(direction.angle.label, systemImage: direction.angle.symbolName)
                    .zoomedSystemFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                Spacer(minLength: 0)
                Text(direction.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                    .zoomedSystemFont(size: 10)
                    .foregroundStyle(.tertiary)
            }

            Text(direction.title)
                .zoomedSystemFont(size: 13, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)

            Text(direction.rationale)
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)

            if isExpanded {
                details
            }

            if let answer = direction.verdictReason, !direction.isProposed {
                Text("\(direction.isPursued ? "Why you're pursuing it" : "Why you set it aside"): \(answer)")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions
        }
        .padding(StudioDesign.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(direction.isPursued ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .opacity(direction.isSetAside ? 0.75 : 1)
        // A group of its own: on a plain container the identifier landed on
        // Pursue, Set aside and every other element inside, in place of theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.directions.card")
        .sheet(isPresented: $isWritingReason) {
            DirectionReasonSheet(title: direction.title, reason: $reason) { written in
                isWritingReason = false
                Task { await vm.answerResearchDirection(direction.id, status: .setAside, reason: written) }
            } cancel: {
                isWritingReason = false
            }
        }
        .confirmationDialog("Delete this direction?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                Task { await vm.deleteResearchDirection(direction.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A later search may propose it again. Set it aside instead to keep it from coming back.")
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
            if !direction.evidence.isEmpty {
                Text("Evidence")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                ForEach(direction.evidence, id: \.self) { item in
                    DirectionEvidenceRow(evidence: item, dismiss: dismiss)
                }
            }
            if let objection = direction.objection {
                labelled("The case against it", objection)
            }
            if let nextStep = direction.nextStep {
                labelled("Cheapest test", nextStep)
            }
        }
        .padding(.top, StudioDesign.Spacing.xSmall)
    }

    private func labelled(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(text)
                .zoomedSystemFont(size: 12)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Answers

    private var actions: some View {
        HStack(spacing: StudioDesign.Spacing.small) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Label(isExpanded ? "Less" : "Evidence and tests", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash)
            .accessibilityIdentifier("studio.directions.card.expand")

            Spacer(minLength: 0)

            switch direction.status {
            case .proposed:
                setAsideMenu
                Button {
                    Task { await vm.answerResearchDirection(direction.id, status: .pursued) }
                } label: {
                    Label("Pursue", systemImage: "arrow.forward.circle")
                        .zoomedSystemFont(size: 12, weight: .medium)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.hoverWash)
                .help("Follow this one; the next search reads it as the kind you want more of")
                .accessibilityIdentifier("studio.directions.card.pursue")
            case .pursued:
                Button {
                    dismiss()
                    vm.requestDirectionChat(direction)
                } label: {
                    Label("Chat about it", systemImage: "bubble.left.and.text.bubble.right")
                        .zoomedSystemFont(size: 12)
                }
                .buttonStyle(.hoverWash)
                .help("Open a chat about this direction with its papers in context")
                .accessibilityIdentifier("studio.directions.card.chat")
                moreMenu
            case .setAside:
                Button {
                    Task { await vm.answerResearchDirection(direction.id, status: .proposed) }
                } label: {
                    Label("Reconsider", systemImage: "arrow.uturn.backward")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash)
                .help("Put it back among the proposals")
                .accessibilityIdentifier("studio.directions.card.reconsider")
                moreMenu
            }
        }
    }

    private var setAsideMenu: some View {
        Menu {
            ForEach(DirectionListing.setAsideReasons, id: \.self) { reason in
                Button(reason) {
                    Task { await vm.answerResearchDirection(direction.id, status: .setAside, reason: reason) }
                }
            }
            Divider()
            Button("In my own words\u{2026}") {
                reason = ""
                isWritingReason = true
            }
            Button("Without a reason") {
                Task { await vm.answerResearchDirection(direction.id, status: .setAside) }
            }
            Divider()
            Button("Delete\u{2026}", role: .destructive) { isConfirmingDelete = true }
        } label: {
            Text("Set aside")
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
        }
        // A borderless Menu redraws its label as a native popup title and
        // drops the font; the button style keeps the label as drawn.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .hoverHighlight()
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Not this one; say why, so the next search knows")
        .accessibilityIdentifier("studio.directions.card.setAside")
    }

    private var moreMenu: some View {
        Menu {
            if direction.isPursued {
                Button("Set aside\u{2026}") {
                    reason = ""
                    isWritingReason = true
                }
            }
            Button("Back to a proposal") {
                Task { await vm.answerResearchDirection(direction.id, status: .proposed) }
            }
            Divider()
            Button("Delete\u{2026}", role: .destructive) { isConfirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis")
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
        }
        // A borderless Menu redraws its label as a native popup title and
        // drops the font; the button style keeps the label as drawn.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .hoverHighlight()
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("studio.directions.card.more")
    }
}

/// One paper or page a Direction rests on: its citation, what it shows, and
/// Open or Add to Library — Open in the Reader when the library has it.
private struct DirectionEvidenceRow: View {
    @Environment(StudioViewModel.self) private var vm
    let evidence: DirectionEvidence
    let dismiss: () -> Void
    @State private var isAdding = false

    var body: some View {
        let librarySourceID = vm.librarySourceID(for: evidence)
        HStack(alignment: .top, spacing: StudioDesign.Spacing.small) {
            Image(systemName: "doc.text")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    if let librarySourceID {
                        dismiss()
                        Task { await vm.openLinkedSourceInReader(librarySourceID, beside: .goals) }
                    } else if let url = evidence.openURL {
                        _ = NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(evidence.title.map { "\(evidence.citation) — \($0)" } ?? evidence.citation)
                        .zoomedSystemFont(size: 12)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.hoverWash)
                .help(librarySourceID != nil ? "Open it in the Reader" : "Open it in the browser")
                Text(evidence.finding)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if librarySourceID != nil {
                Text("In library")
                    .zoomedSystemFont(size: 10)
                    .foregroundStyle(.tertiary)
            } else if evidence.openURL != nil {
                Button {
                    isAdding = true
                    Task {
                        await vm.addDirectionEvidenceToLibrary(evidence)
                        isAdding = false
                    }
                } label: {
                    Label(isAdding ? "Adding" : "Add", systemImage: "plus")
                        .zoomedSystemFont(size: 11)
                }
                .buttonStyle(.hoverWash)
                .disabled(isAdding)
                .help("Add it to your library")
                .accessibilityIdentifier("studio.directions.evidence.add")
            }
        }
    }
}

/// Set aside, in the learner's own words.
private struct DirectionReasonSheet: View {
    let title: String
    @Binding var reason: String
    let save: (String) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.medium) {
            Text("Why set it aside?")
                .zoomedSystemFont(size: 15, weight: .semibold)
            Text(title)
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("The next search reads this", text: $reason, axis: .vertical)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: 13)
                .lineLimit(2...5)
                .padding(StudioDesign.Spacing.small)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .focused($focused)
                .accessibilityIdentifier("studio.directions.reason")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Set aside") { save(reason) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(StudioDesign.Spacing.xLarge)
        .frame(width: 420)
        .onAppear { focused = true }
    }
}
