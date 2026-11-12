import AppKit
import SwiftUI

/// A selected clip in the Canvas's inspector: where it was cut from, the
/// learner's note on it (the mark's note, shown under its picture on the
/// card, so the note is also why it is on the canvas: no second field for an
/// annotation), Ask in Chat, and a ⋯ with Add to Chat, Colour ▸, Copy Picture,
/// Take Off Canvas and Delete Clip (docs/knowledge-map-design.md, "Clips"). The
/// paper line opens the page. A talk's slide also lists the papers read off
/// it, each placed under the slide (or added to the library first) with a
/// click.
struct KnowledgeMapClipInspector: View {
    let clipID: String
    /// The clip as the selection names it (`clip:<id>`).
    let ref: String

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @State private var note = ""
    @State private var loaded = false
    @FocusState private var noteFocused: Bool
    @State private var citations: [VideoCitedPaper] = []
    @State private var hanging: Set<String> = []

    private var clip: SourceHighlight? { vm.knowledgeMap(in: windowState).clips[clipID] }

    var body: some View {
        if let clip {
            let isPassage = ReaderClip.isPassage(clip)
            let slide = ReaderClip.slide(of: clip)
            VStack(alignment: .leading, spacing: 10) {
                // Where it was cut from; the line is the way to the page.
                if let source = vm.articlesById[clip.sourceID] {
                    Button { vm.task(in: windowState) { await vm.openKnowledgeMapClip(clipID, in: windowState) } } label: {
                        Text(source.title + (slide.map { ", slide \($0)" } ?? (ReaderClip.page(of: clip) ?? ReaderClip.passagePage(of: clip) ?? vm.knowledgeMap(in: windowState).passagePage(clip.id)).map { ", page \($0)" } ?? ""))
                            .zoomedSystemFont(size: 12)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                    .help(slide != nil ? "Open the video beside the Canvas at this slide" : isPassage ? "Open the paper beside the Canvas at this passage" : "Open the paper beside the Canvas at this clip, outlined")
                    .accessibilityIdentifier("knowledgeMap.clip.open")
                }
                if slide != nil, !citations.isEmpty {
                    citedOnSlide
                }
                TextField("Your note on this clip", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...8)
                    .focused($noteFocused)
                    .onSubmit(commit)
                    .onChange(of: noteFocused) { _, focused in
                        if !focused { commit() }
                    }
                    .accessibilityIdentifier("knowledgeMap.clip.note")
                HStack(spacing: 10) {
                    Button("Ask in Chat") { vm.requestChatAboutKnowledgeMapSelection([ref]) }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                        .accessibilityIdentifier("knowledgeMap.selection.ask")
                    Spacer()
                    Menu {
                        Button("Add to Chat") { vm.addKnowledgeMapCardsToChat([ref], in: windowState) }
                            .help("Give the chat beside the canvas this clip to work from, or open one with it")
                            .accessibilityIdentifier("knowledgeMap.selection.addToChat")
                        Divider()
                        Button("Open Beside", systemImage: "rectangle.righthalf.inset.filled") {
                            vm.task(in: windowState) { await vm.openKnowledgeMapItemBeside(ref, in: windowState) }
                        }
                        // The card's colour: one of eight, or the kind's own.
                        if let placement = vm.knowledgeMap(in: windowState).layout.placements[ref] {
                            KnowledgeMapColourMenu(selected: placement.color, defaultIsSelected: placement.color == nil) { hex in
                                vm.setKnowledgeMapCardColor([ref], to: hex)
                            }
                        }
                        KnowledgeMapCardActionItems(refs: [ref])
                        Divider()
                        if !isPassage {
                            Button("Copy Picture", action: copyPicture)
                        }
                        Button("Take Off Canvas") { vm.knowledgeMap(in: windowState).unplace([ref]) }
                        Divider()
                        Button("Delete Clip", role: .destructive) {
                            vm.task(in: windowState) { await vm.deleteKnowledgeMapClip(clipID) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .zoomedSystemFont(size: 12)
                            .foregroundStyle(.secondary)
                    }
                    // A borderless Menu redraws its label as a native popup
                    // title and drops the font; the button style keeps it.
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .hoverHighlight()
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("knowledgeMap.clip.more")
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                note = clip.note
            }
            .onDisappear(perform: commit)
            .task(id: clipID) {
                citations = slide == nil ? [] : await vm.withWindow(windowState) { await vm.knowledgeMapSlideCitations(clipID: clipID) }
            }
        }
    }

    /// The papers read off this slide: one line each, with Place when the
    /// library holds it and it is not on the canvas, Add when it is not in the
    /// library yet.
    private var citedOnSlide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cited on this slide")
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
            ForEach(citations) { paper in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(paper.title)
                            .zoomedSystemFont(size: 12)
                            .lineLimit(2)
                        let line = [paper.authors.map { String($0.prefix(40)) }, paper.year].compactMap { $0 }.joined(separator: " · ")
                        if !line.isEmpty {
                            Text(line)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    citationAction(paper)
                }
            }
        }
    }

    @ViewBuilder
    private func citationAction(_ paper: VideoCitedPaper) -> some View {
        let held = vm.librarySourceID(citedBy: paper)
        let placed = held.map { vm.knowledgeMap(in: windowState).layout.placements[KnowledgeMap.ItemRef(kind: .source, id: vm.canonicalSourceID($0)).description] != nil } ?? false
        if hanging.contains(paper.id) {
            ProgressView().controlSize(.small)
        } else if placed {
            Text("On canvas")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.tertiary)
        } else if held != nil || paper.url?.isEmpty == false {
            Button(held != nil ? "Place" : "Add") {
                hanging.insert(paper.id)
                vm.task(in: windowState) {
                    await vm.hangCitedPaper(paper, underSlideClip: clipID)
                    hanging.remove(paper.id)
                }
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
            .help(held != nil ? "Set it under this slide, with an arrow from the slide" : "Add it to your library and set it under this slide")
        } else {
            Text("Not found")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.tertiary)
                .help("No catalog had this paper, so it cannot be added")
        }
    }

    private func commit() {
        guard let clip, note.trimmingCharacters(in: .whitespacesAndNewlines) != clip.note else { return }
        let text = note
        vm.task(in: windowState) { await vm.setKnowledgeMapClipNote(text, clipID: clipID) }
    }

    private func copyPicture() {
        guard let clip else { return }
        Task {
            guard let dataURL = await vm.knowledgeMapClipPicture(clip),
                  let image = SourceImageCatalog.parseDataURL(dataURL) else {
                vm.showToast("Could not draw that clip")
                return
            }
            if ChatSourceImage(data: image.data, mediaType: image.mediaType).copyToPasteboard() {
                vm.showToast("Picture copied")
            }
        }
    }
}
