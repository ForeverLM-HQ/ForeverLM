// The source banner and the retrieved-passage card in a chat.

import SwiftUI

/// One source under an expanded day listing ("What you watched today"): its
/// picture — a video's still at 16:9, anything else its library thumbnail —
/// with the title and channel or author beside it. Clicking opens it in the
/// Reader, so the list doubles as a way back to what was watched.
struct ReviewChatSourceBanner: View {
    let source: StudioArticle
    @Environment(StudioViewModel.self) private var vm

    private static let pictureSize = CGSize(width: 112, height: 63)

    private var byline: String? {
        let candidates: [String?] = [source.displayAuthor, vm.sourceGroupTitle(for: source), source.displayDomain]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private var typeLabel: String {
        switch source.sourceType {
        case .article, .unclassified, .manual: return "Article"
        case .paper: return "Paper"
        case .podcast: return "Podcast"
        case .book: return "Book"
        case .course: return "Course lecture"
        case .meeting: return "Meeting"
        case .video: return "Video"
        case .xPost: return "Post"
        }
    }

    @ViewBuilder
    private var picture: some View {
        if source.sourceType == .video || source.sourceType == .course,
           let url = SourceArtwork.remoteURL(for: source) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    SourceThumbnail(source: source, size: Self.pictureSize.height)
                default:
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: Self.pictureSize.width, height: Self.pictureSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            SourceThumbnail(source: source, size: Self.pictureSize.height)
                .frame(width: Self.pictureSize.width, height: Self.pictureSize.height)
                .background(
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
    }

    var body: some View {
        Button {
            Task { await vm.openLinkedSourceInReader(source.id) }
        } label: {
            HStack(spacing: 11) {
                picture

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let byline {
                        Text(byline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(typeLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 9, inset: 0))
        .help("Open \(source.title)")
    }
}

/// One retrieved source under an expanded retrieval row: the library card the
/// read-source row already uses, with the passage the tutor read beneath it as
/// ordinary prose. The passage is clipped so a long excerpt never turns the
/// transcript into a second reader; the source itself is one click away.
struct ReviewChatRetrievedPassageCard: View {
    let passage: ReviewSessionManager.Message.ToolActivity.RetrievedPassage
    @State private var showsWholePassage = false

    private static let clipLength = 700

    private var isClipped: Bool {
        passage.passage.count > Self.clipLength && !showsWholePassage
    }

    private var visiblePassage: String {
        guard isClipped else { return passage.passage }
        let head = passage.passage.prefix(Self.clipLength)
        // Cut at a word, not mid-word.
        let cut = head.lastIndex(where: { $0.isWhitespace }).map { head[..<$0] } ?? head
        return String(cut).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private var sourceTypeLabel: String? {
        guard let type = StudioSourceType(rawValue: passage.sourceType) else { return nil }
        switch type {
        case .article, .unclassified, .manual: return "Article"
        case .paper: return "Paper"
        case .podcast: return "Podcast"
        case .book: return "Book"
        case .course: return "Course"
        case .meeting: return "Meeting"
        case .video: return "Video"
        case .xPost: return "Post"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                if let presentation = passage.presentation {
                    SourceThumbnail(source: presentation.source, size: 34)
                } else {
                    Image(systemName: "doc.text")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(width: 34, height: 34)
                        .background(
                            Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(passage.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let sourceTypeLabel {
                            Text(sourceTypeLabel)
                        }
                        if passage.addedByForeverLM {
                            Text("Added by ForeverLM")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }

            if !passage.passage.isEmpty {
                Text(visiblePassage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if passage.passage.count > Self.clipLength {
                    Button(showsWholePassage ? "Show less" : "Show more") {
                        showsWholePassage.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }
}
