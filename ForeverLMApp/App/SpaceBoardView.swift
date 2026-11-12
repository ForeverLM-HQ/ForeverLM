#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The Board in the Space
//
// The learner's own columns of cards (docs-site/board.md): To do, In progress
// and Done, with a Today view that gathers the day's plan. Its cards are the
// tasks of one Notebook (`TeamContentIdentity.personalBoardNotebookID`), drawn
// by `NotebookTasksBoardView`; this file is the Space's page around it and the
// drop target a card lands in.

/// The Space's Board place: the place head (title, search, New Card), the
/// All and Today scopes, and the columns, which run to the pane's edge where a
/// list's column would be capped.
struct SpaceBoardPage: View {
    @Environment(StudioViewModel.self) private var vm
    @Binding var searchText: String
    var searchFocusRequest = 0

    /// This Mac's last view of the board, as the Space remembers its layout.
    @AppStorage(Prefs.Space.boardLens) private var lensRaw
    @State private var addFocusRequest = 0

    private var lens: NotebookTaskBoard.Lens {
        lensRaw == "today" ? .today : .all
    }

    private func choose(_ lens: NotebookTaskBoard.Lens) {
        lensRaw = lens == .today ? "today" : "all"
    }

    private var isOwnLibrary: Bool { vm.activeTeamID == nil }

    /// What is still open on today's plate, for the Today scope's count.
    private var todayCount: Int {
        guard let board = vm.boardNotebook else { return 0 }
        return NotebookTaskBoard.lensed(vm.tasks(for: board.id), .today, now: Date())
            .filter { $0.status != .done }
            .count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                SpacePlaceHeader(
                    searchText: $searchText,
                    searchFocusRequest: searchFocusRequest,
                    searchPrompt: "Search cards"
                ) {
                    SpacePlaceTitle(title: SpaceDestination.board.title)
                } actions: {
                    if isOwnLibrary, !vm.isActiveLibraryReadOnly {
                        SpaceDarkPillButton(title: "New Card", systemImage: nil, image: nil) {
                            addFocusRequest += 1
                        }
                        .accessibilityIdentifier("space.board.newCard")
                    }
                }
                HStack(spacing: 8) {
                    ForEach(NotebookTaskBoard.Lens.allCases, id: \.self) { option in
                        SpaceScopePill(
                            title: option.title,
                            isSelected: lens == option,
                            count: option == .today ? todayCount : nil
                        ) { choose(option) }
                    }
                    Spacer(minLength: 8)
                }
            }
            .padding(.horizontal, SpacePlaceMetrics.horizontalPadding)
            .padding(.top, SpacePlaceMetrics.topPadding)

            if !isOwnLibrary {
                SpaceEmptyLine(systemImage: SpaceDestination.board.symbolName, text: "The Board is in your own library")
                    .frame(maxWidth: .infinity)
                    .padding(.top, SpacePlaceMetrics.emptyTopPadding)
            } else if let board = vm.boardNotebook {
                NotebookTasksBoardView(
                    goal: board,
                    lens: lens,
                    query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                    addFocusRequest: addFocusRequest,
                    horizontalPadding: SpacePlaceMetrics.horizontalPadding
                )
                .padding(.top, 16)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.top, SpacePlaceMetrics.emptyTopPadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space.board")
        // The Board's Notebook is made on first use, never at launch.
        .task(id: isOwnLibrary) {
            if isOwnLibrary { await vm.loadBoard() }
        }
    }
}

// MARK: - Dropping a card

/// Where a hovering card would land in a column: in front of `beforeID`, or at
/// the bottom when nil.
struct SpaceBoardDropTarget: Equatable {
    var beforeID: String?
}

/// The one drop target of a column. It reads the card under the pointer from
/// the cards' frames (in the column's coordinate space), since a target on
/// each card never receives a drag on macOS.
struct SpaceBoardDropDelegate: DropDelegate {
    let orderedIDs: [String]
    let frames: [String: CGRect]
    let isEnabled: Bool
    @Binding var target: SpaceBoardDropTarget?
    let move: @MainActor @Sendable (_ taskID: String, _ beforeID: String?) -> Void

    /// What a card drags: its task's id, for this process only.
    static func dragProvider(taskID: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(taskID.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.boardCard.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// The card the point is above: the first whose middle lies below it.
    func resolve(_ point: CGPoint) -> SpaceBoardDropTarget {
        for id in orderedIDs {
            if let frame = frames[id], point.y < frame.midY { return SpaceBoardDropTarget(beforeID: id) }
        }
        return SpaceBoardDropTarget(beforeID: nil)
    }

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && info.hasItemsConforming(to: [.boardCard])
    }

    /// Whether the learner is still holding the mouse down. AppKit can send a
    /// last update after the drop, which would bring the line back and leave it
    /// there; with the button up there is
    /// no drag left to show.
    private var isDragLive: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    func dropEntered(info: DropInfo) {
        target = isDragLive ? resolve(info.location) : nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        target = isDragLive ? resolve(info.location) : nil
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        target = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let beforeID = resolve(info.location).beforeID
        target = nil
        guard let provider = info.itemProviders(for: [.boardCard]).first else { return false }
        let move = move
        provider.loadDataRepresentation(forTypeIdentifier: UTType.boardCard.identifier) { data, _ in
            guard let data, let taskID = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in move(taskID, beforeID) }
        }
        return true
    }
}

/// The line that shows where a dragged card will land.
struct SpaceBoardInsertionBar: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .accessibilityHidden(true)
    }
}
#endif
