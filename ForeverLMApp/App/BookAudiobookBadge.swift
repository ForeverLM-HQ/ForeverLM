#if os(macOS)
import SwiftUI

/// The speaker badge on a book's row: filled when every readable chapter has
/// text-to-speech audio, dimmed with a count while some do, absent otherwise.
/// Chapter rows already wear the same speaker once their audio lands; this is
/// the book-level answer to "is the audiobook done", without expanding it.
struct BookAudiobookBadge: View {
    /// Chapters text-to-speech could narrate, in reading order.
    let chapterIDs: [String]

    @State private var readyCount: Int?

    var body: some View {
        Group {
            if let readyCount, !chapterIDs.isEmpty {
                if readyCount == chapterIDs.count {
                    Image(systemName: "speaker.wave.2.fill")
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(Color.accentColor)
                        .help("Audiobook ready: every chapter has text-to-speech audio")
                        .accessibilityLabel("Audiobook ready")
                } else if readyCount > 0 {
                    Image(systemName: "speaker.wave.2")
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                        .help("\(readyCount) of \(chapterIDs.count) chapters have text-to-speech audio")
                        .accessibilityLabel("\(readyCount) of \(chapterIDs.count) chapters have audio")
                }
            }
        }
        .task(id: chapterIDs) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: ArticleSpeechAudioCache.statusDidChangeNotification)) { notification in
            guard let sourceID = notification.object as? String, chapterIDs.contains(sourceID) else { return }
            Task { await refresh() }
        }
    }

    /// Stats one marker file per chapter, so it runs off the main actor the
    /// way the chapter rows' own badge does.
    private func refresh() async {
        let ids = chapterIDs
        let count = await Task.detached(priority: .utility) {
            ids.filter { ArticleSpeechAudioCache.hasCachedAudio(sourceID: $0) }.count
        }.value
        readyCount = count
    }
}
#endif
