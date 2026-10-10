import PDFKit
import SwiftUI
import WebKit

// Find inside a source on the phone. One bar, one state, two performers: the
// text reader steps WebKit's own find through the rendered document, the PDF
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
    /// to show — "3 of 14", "14 matches", "No matches", or "" for no query.
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

/// Find over the text reader: WebKit steps from the current selection to the
/// next match, wrapping, and the document's total is counted once per query so
/// the bar can say how many there are.
@MainActor
final class MobileWebFindPerformer: MobileReaderFindPerformer {
    private weak var webView: WKWebView?
    private var lastQuery = ""
    private var total: Int?

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// The document was rebuilt (a font-size change reloads it), so the count
    /// and the position no longer describe what is on screen.
    func documentChanged() {
        lastQuery = ""
        total = nil
    }

    func find(_ query: String, backwards: Bool) async -> String {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let webView else { return "" }
        guard !needle.isEmpty else {
            clearFind()
            return ""
        }

        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        let found = await withCheckedContinuation { continuation in
            webView.find(needle, configuration: configuration) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
        guard found else {
            lastQuery = needle
            total = 0
            return "No matches"
        }
        if needle != lastQuery || total == nil {
            lastQuery = needle
            total = await Self.count(needle, in: webView)
        }
        guard let total, total > 0 else { return "" }
        return total == 1 ? "1 match" : "\(total) matches"
    }

    func clearFind() {
        lastQuery = ""
        total = nil
        webView?.evaluateJavaScript("window.getSelection()?.removeAllRanges();") { _, _ in }
    }

    /// Occurrences of `needle` in the visible text, case-folded the way
    /// WebKit's find is. The needle travels as JSON so no query can break out
    /// of the script.
    private static func count(_ needle: String, in webView: WKWebView) async -> Int? {
        guard let data = try? JSONSerialization.data(withJSONObject: [needle]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let script = """
        (() => {
          const text = (document.body.innerText || document.body.textContent || '').toLocaleLowerCase();
          const needle = \(json)[0].toLocaleLowerCase();
          if (!needle) return 0;
          let count = 0, from = 0;
          while ((from = text.indexOf(needle, from)) >= 0) { count += 1; from += needle.length; }
          return count;
        })()
        """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: (value as? NSNumber)?.intValue)
            }
        }
    }
}
