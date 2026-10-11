import PDFKit
import SwiftUI
import WebKit

// Find inside a source on the phone. One bar, one state, two performers: the
// text reader steps WebKit's text search through the rendered document, the PDF
// reader steps PDFKit's `findString` matches, and both report where they landed
// the way the Mac reader's find bar does. The system `UIFindInteraction` was
// the first choice — it is what Safari shows — but `PDFView` never reports it
// enabled on iOS 26 whatever the view's state (measured 2026-09-03 in the
// simulator: after init, in a window, with a document, after layout), so the
// reader owns its find rather than offering a button that opens nothing.

/// What a reader surface offers Find: step to the next or previous match and
/// say where that landed; drop the match when the bar closes.
@MainActor
protocol MobileReaderFindPerformer: AnyObject {
    /// Moves to the next (or previous) match of `query` and returns the status
    /// to show — "3 of 14", "No matches", or "" for no query.
    func find(_ query: String, backwards: Bool) async -> String
    func clearFind()
}

/// The find bar's state, owned by the reader screen for as long as it is open.
@MainActor
final class MobileReaderFindState: ObservableObject {
    @Published var isPresented = false
    @Published var query = ""
    @Published private(set) var statusText = ""

    /// The surface on screen. Installed by the content view that renders the
    /// source, and weak so a dismantled view simply drops out.
    weak var performer: MobileReaderFindPerformer?

    private var searchTask: Task<Void, Never>?

    /// As-you-type search waits this long for the next keystroke.
    static let typingDebounce: UInt64 = 250_000_000

    func show() {
        isPresented = true
    }

    func close() {
        searchTask?.cancel()
        isPresented = false
        query = ""
        statusText = ""
        performer?.clearFind()
    }

    func toggle() {
        if isPresented { close() } else { show() }
    }

    /// Return, or the chevrons: step to the next or previous match now.
    func search(backwards: Bool = false) {
        searchTask?.cancel()
        let query = query
        searchTask = Task { [weak self] in
            guard let self, let performer else { return }
            let status = await performer.find(query, backwards: backwards)
            guard !Task.isCancelled else { return }
            statusText = status
        }
    }

    /// A keystroke: an emptied field clears the match at once, anything else
    /// searches after a short pause so a word typed quickly searches once.
    func queryChanged() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusText = ""
            performer?.clearFind()
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.typingDebounce)
            guard !Task.isCancelled, let self, let performer else { return }
            let status = await performer.find(trimmed, backwards: false)
            guard !Task.isCancelled else { return }
            statusText = status
        }
    }
}

/// The bar itself, shown under the navigation bar while Find is open. Return
/// steps forward, the chevrons step either way, Done closes.
struct MobileReaderFindBar: View {
    @ObservedObject var state: MobileReaderFindState
    @FocusState private var isFocused: Bool

    private var hasQuery: Bool {
        !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in this source", text: $state.query)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit { state.search() }
                .onChange(of: state.query) { _, _ in state.queryChanged() }
                .accessibilityIdentifier("reader.findField")

            if !state.statusText.isEmpty {
                Text(state.statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("reader.findStatus")
            }

            Button {
                state.search(backwards: true)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(minWidth: 28, minHeight: 28)
            }
            .disabled(!hasQuery)
            .accessibilityLabel("Previous match")

            Button {
                state.search()
            } label: {
                Image(systemName: "chevron.down")
                    .frame(minWidth: 28, minHeight: 28)
            }
            .disabled(!hasQuery)
            .accessibilityLabel("Next match")

            Button("Done") {
                state.close()
            }
            .fontWeight(.semibold)
            .accessibilityIdentifier("reader.findDone")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.vertical, MobileDesign.Spacing.medium)
        .mobileFloatingSurface(cornerRadius: MobileDesign.Radius.compact)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.top, MobileDesign.Spacing.small)
        .onAppear { isFocused = true }
        .accessibilityIdentifier("reader.findBar")
    }
}

/// Find over a PDF: the document's matches in page order, stepped with wrap,
/// each selected and scrolled into view. Mirrors the Mac's `performPDFFind`.
@MainActor
final class MobilePDFFindPerformer: MobileReaderFindPerformer {
    private weak var pdfView: PDFView?
    private var lastQuery = ""
    private weak var searchedDocument: PDFDocument?
    private var matches: [PDFSelection] = []
    private var index = -1

    init(pdfView: PDFView) {
        self.pdfView = pdfView
    }

    func find(_ query: String, backwards: Bool) async -> String {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pdfView else { return "" }
        guard !needle.isEmpty else {
            clearFind()
            return ""
        }
        guard let document = pdfView.document else { return "No matches" }

        if needle != lastQuery || document !== searchedDocument {
            matches = document.findString(needle, withOptions: [.caseInsensitive, .diacriticInsensitive])
            lastQuery = needle
            searchedDocument = document
            index = backwards ? matches.count : -1
        }
        guard !matches.isEmpty else {
            index = -1
            pdfView.clearSelection()
            return "No matches"
        }

        if backwards {
            index = index <= 0 ? matches.count - 1 : index - 1
        } else {
            index = (index + 1) % matches.count
        }
        let selection = matches[index]
        selection.color = UIColor.systemYellow.withAlphaComponent(0.6)
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
        return "\(index + 1) of \(matches.count)"
    }

    func clearFind() {
        matches = []
        lastQuery = ""
        searchedDocument = nil
        index = -1
        pdfView?.clearSelection()
    }
}

/// Find over the text reader: WebKit's text search, the `UITextSearching`
/// side of WKWebView that Safari's find bar drives, lists every match in the
/// document, and the performer steps through them with wrap. WebKit shows the
/// highlighted match as the page's selection, so `clearFind` drops the
/// decoration and then the selection.
///
/// Not `WKWebView.find(_:configuration:)`: after it finds a match, iOS stops
/// showing the page's own selection changes, so the match stayed on screen
/// with its handles after the bar closed, whatever script cleared it, until a
/// tap on the page (iOS 26.5 Simulator, 2026-10-10). The text search leaves the
/// selection the page's to change.
///
/// UIKit marks both protocols Swift-private, so Swift spells the public
/// `UITextSearching` and `UITextSearchAggregator` with two underscores.
/// WKWebView adopts `UITextSearching` without saying so in its header; it is
/// what the web view's own `findInteraction` searches.
@MainActor
final class MobileWebFindPerformer: MobileReaderFindPerformer {
    private weak var webView: WKWebView?
    private var lastQuery = ""
    private var matches: [UITextRange] = []
    private var index = -1
    /// The matches describe a document that is no longer there.
    private var matchesAreStale = false
    /// Moves on with every search and every clear, so a search that finishes
    /// after a newer one, or after the bar closed, changes nothing.
    private var generation = 0

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// The document changed (a font-size change reloads it, a book page takes
    /// chapters in and out), so the matches' places in it no longer hold. The
    /// next step searches again and carries on from the match on screen.
    func documentChanged() {
        matchesAreStale = true
    }

    func find(_ query: String, backwards: Bool) async -> String {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let webView else { return "" }
        guard !needle.isEmpty else {
            clearFind()
            return ""
        }
        guard let searchable = webView as? __UITextSearching else { return "" }

        if needle != lastQuery || matchesAreStale {
            generation += 1
            let search = generation
            // Like WebKit's own find, start from what the page has selected:
            // the match on screen, or the learner's selection.
            let position = await Self.selectionPosition(of: needle, in: webView)
            guard search == generation else { return "" }
            searchable.clearAllDecoratedFoundText()
            let found = await Self.matches(of: needle, in: searchable)
            guard search == generation else { return "" }
            matches = found
            lastQuery = needle
            matchesAreStale = false
            if let position {
                index = position.isMatch || backwards ? position.before : position.before - 1
            } else {
                index = backwards ? matches.count : -1
            }
        }
        guard !matches.isEmpty else {
            index = -1
            dropSelection()
            return "No matches"
        }

        // Undecorated first: WebKit skips a range already in the style asked
        // for, so a match highlighted once would not take the selection back.
        if matches.indices.contains(index) {
            searchable.decorateFound(matches[index], inDocument: nil, using: .normal)
        }
        if backwards {
            index = index <= 0 || index > matches.count ? matches.count - 1 : index - 1
        } else {
            index = index < -1 || index >= matches.count - 1 ? 0 : index + 1
        }
        let match = matches[index]
        searchable.decorateFound(match, inDocument: nil, using: .highlighted)
        searchable.scrollRangeToVisible?(match, inDocument: nil)
        return "\(index + 1) of \(matches.count)"
    }

    func clearFind() {
        generation += 1
        lastQuery = ""
        matches = []
        index = -1
        matchesAreStale = false
        (webView as? __UITextSearching)?.clearAllDecoratedFoundText()
        dropSelection()
    }

    /// The page's selection is how WebKit shows the match.
    private func dropSelection() {
        webView?.evaluateJavaScript("window.getSelection()?.removeAllRanges();") { _, _ in }
    }

    /// Every match of `needle` in the document, in reading order.
    private static func matches(of needle: String, in searchable: __UITextSearching) async -> [UITextRange] {
        await withCheckedContinuation { continuation in
            let results = MobileWebFindResults { continuation.resume(returning: $0) }
            searchable.performTextSearch(
                withQueryString: needle,
                using: MobileWebFindOptions(),
                resultAggregator: results
            )
        }
    }

    /// Where the page's selection sits among the matches of `needle`: how many
    /// begin before it, and whether it is one of them. nil with nothing
    /// selected. The needle travels as JSON so no query can break out of the
    /// script.
    private static func selectionPosition(of needle: String, in webView: WKWebView) async -> (before: Int, isMatch: Bool)? {
        guard let data = try? JSONSerialization.data(withJSONObject: [needle]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let script = """
        (() => {
          const needle = \(json)[0].toLocaleLowerCase();
          const selection = window.getSelection();
          if (!needle || !document.body || !selection || selection.rangeCount === 0) return null;
          const start = selection.getRangeAt(0);
          const before = document.createRange();
          before.setStart(document.body, 0);
          before.setEnd(start.startContainer, start.startOffset);
          const text = before.toString().toLocaleLowerCase();
          let count = 0, from = 0;
          while ((from = text.indexOf(needle, from)) >= 0) { count += 1; from += needle.length; }
          return [count, selection.toString().toLocaleLowerCase() === needle];
        })()
        """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                guard let pair = value as? [Any], pair.count == 2,
                      let before = (pair[0] as? NSNumber)?.intValue,
                      let isMatch = (pair[1] as? NSNumber)?.boolValue else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (before, isMatch))
            }
        }
    }
}

/// Collects one search's matches and hands them over when WebKit says it has
/// finished.
private final class MobileWebFindResults: NSObject, __UITextSearchAggregator {
    private var ranges: [UITextRange] = []
    private var onFinish: (([UITextRange]) -> Void)?

    init(onFinish: @escaping ([UITextRange]) -> Void) {
        self.onFinish = onFinish
    }

    var allFoundRanges: NSOrderedSet { NSOrderedSet(array: ranges) }

    func found(_ range: UITextRange, forSearch string: String, inDocument document: (any NSCopying & NSObjectProtocol)?) {
        ranges.append(range)
    }

    func invalidateFound(_ range: UITextRange, inDocument document: (any NSCopying & NSObjectProtocol)?) {
        ranges.removeAll { $0 === range }
    }

    func invalidate() {
        ranges.removeAll()
    }

    func finishedSearching() {
        onFinish?(ranges)
        onFinish = nil
    }
}

/// Case-insensitive, as WebKit's find was. The options' properties are
/// read-only and default to an exact-case match, so the search asks through a
/// subclass.
private final class MobileWebFindOptions: UITextSearchOptions {
    override var stringCompareOptions: NSString.CompareOptions { .caseInsensitive }
}
