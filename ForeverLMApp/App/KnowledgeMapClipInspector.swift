import AppKit
import SwiftUI

/// A selected clip in the Canvas's inspector: where it was cut from, the
/// learner's note on it (the mark's note, shown under its picture on the
/// card, so the note is also why it is on the canvas: no second field for an
/// annotation), Ask in Chat and Add to Chat, and a ⋯ with Copy Picture, Take
/// Off Canvas and Delete Clip (docs/knowledge-map-design.md, "Clips"). The
/// paper line opens the page.
struct KnowledgeMapClipInspector: View {
    let clipID: String
    /// The clip as the selection names it (`clip:<id>`).
    let ref: String

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @State private var note = ""
    @State private var loaded = false
    @FocusState private var noteFocused: Bool

    private var clip: SourceHighlight? { vm.knowledgeMap.clips[clipID] }

    var body: some View {
        if let clip {
            let isPassage = ReaderClip.isPassage(clip)
            VStack(alignment: .leading, spacing: 10) {
                // Where it was cut from; the line is the way to the page.
                if let source = vm.articlesById[clip.sourceID] {
                    Button { Task { await vm.openKnowledgeMapClip(clipID, in: windowState) } } label: {
                        Text(source.title + ((ReaderClip.page(of: clip) ?? ReaderClip.passagePage(of: clip) ?? vm.knowledgeMap.passagePage(clip.id)).map { ", page \($0)" } ?? ""))
                            .zoomedSystemFont(size: 12)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                    .help(isPassage ? "Open the paper beside the Canvas at this passage" : "Open the paper beside the Canvas at this clip, outlined")
                    .accessibilityIdentifier("knowledgeMap.clip.open")
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
                // The card's colour: one of eight, or the kind's own.
                if let colour = vm.knowledgeMap.layout.placements[ref] {
                    KnowledgeMapColorRow(selected: colour.color, defaultIsSelected: colour.color == nil) { hex in
                        vm.setKnowledgeMapCardColor([ref], to: hex)
                    }
                }
                HStack(spacing: 10) {
                    Button("Ask in Chat") { vm.requestChatAboutKnowledgeMapSelection([ref]) }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                        .accessibilityIdentifier("knowledgeMap.selection.ask")
                    Button("Add to Chat") { vm.addKnowledgeMapCardsToChat([ref], in: windowState) }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                        .help("Give the chat beside the canvas this clip to work from, or open one with it")
                        .accessibilityIdentifier("knowledgeMap.selection.addToChat")
                    Spacer()
                    Menu {
                        Button("Open Beside", systemImage: "rectangle.righthalf.inset.filled") {
                            Task { await vm.openKnowledgeMapItemBeside(ref, in: windowState) }
                        }
                        KnowledgeMapCardActionItems(refs: [ref])
                        Divider()
                        if !isPassage {
                            Button("Copy Picture", action: copyPicture)
                        }
                        Button("Take Off Canvas") { vm.knowledgeMap.unplace([ref]) }
                        Divider()
                        Button("Delete Clip", role: .destructive) {
                            Task { await vm.deleteKnowledgeMapClip(clipID) }
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
        }
    }

    private func commit() {
        guard let clip, note.trimmingCharacters(in: .whitespacesAndNewlines) != clip.note else { return }
        let text = note
        Task { await vm.setKnowledgeMapClipNote(text, clipID: clipID) }
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
