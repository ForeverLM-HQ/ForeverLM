import Foundation

// The share sheet's rules (docs/notebooks-design.md, "iPhone"): the notebooks
// it offers and the one it preselects, what it shows of a shared item and the
// title it queues it under, and the notebook adds a drain of the queue makes.
// The app and the share extension both compile this file, beside
// MobileShareInbox.swift. The extension cannot read the CloudKit catalog and
// compiles nothing else of the library, so everything here is Foundation only.

/// A notebook as the share sheet offers it: its id and title, nothing else.
struct MobileShareNotebook: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
}

/// The share sheet's notebooks, in Home's order, as the app writes them into
/// the app group and the extension reads them.
enum MobileShareNotebookList {
    /// The list as it is written and read: titles trimmed, an entry with no
    /// id or a repeated id dropped, the order kept.
    static func normalized(_ notebooks: [MobileShareNotebook]) -> [MobileShareNotebook] {
        var seen = Set<String>()
        return notebooks.compactMap { notebook in
            guard !notebook.id.isEmpty, seen.insert(notebook.id).inserted else { return nil }
            return MobileShareNotebook(
                id: notebook.id,
                title: notebook.title.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func encode(_ notebooks: [MobileShareNotebook]) -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(normalized(notebooks))
    }

    /// Nil when the bytes are not a list this build can read.
    static func decode(_ data: Data) -> [MobileShareNotebook]? {
        (try? PropertyListDecoder().decode([MobileShareNotebook].self, from: data)).map(normalized)
    }

    /// The choice the sheet opens on: the notebook last shared into while it
    /// is still listed, else none ("Not in a notebook").
    static func preselected(lastUsed: String?, in notebooks: [MobileShareNotebook]) -> String? {
        guard let lastUsed, notebooks.contains(where: { $0.id == lastUsed }) else { return nil }
        return lastUsed
    }

    /// A notebook's name in the picker, as the phone names one with none.
    static func displayTitle(of notebook: MobileShareNotebook) -> String {
        notebook.title.isEmpty ? "Untitled" : notebook.title
    }
}

/// Where the share sheet's notebooks and its last choice are kept: the shared
/// app group's defaults, on this device only. The app writes the list; the
/// extension reads it, and writes the last choice only when Add queues an
/// item. A test passes its own suite.
struct MobileShareNotebookStore {
    static let suiteName = MobileShareInbox.appGroup
    static let notebooksKey = "share.notebooks"
    static let lastUsedKey = "share.lastNotebookID"

    let defaults: UserDefaults

    /// Nil when the app group is not available to this process.
    static var shared: MobileShareNotebookStore? {
        UserDefaults(suiteName: suiteName).map { MobileShareNotebookStore(defaults: $0) }
    }

    var notebooks: [MobileShareNotebook] {
        defaults.data(forKey: Self.notebooksKey).flatMap(MobileShareNotebookList.decode) ?? []
    }

    /// Writes the list only when it changed. True when it wrote.
    @discardableResult
    func save(_ notebooks: [MobileShareNotebook]) -> Bool {
        let list = MobileShareNotebookList.normalized(notebooks)
        guard list != self.notebooks, let data = MobileShareNotebookList.encode(list) else { return false }
        defaults.set(data, forKey: Self.notebooksKey)
        return true
    }

    var lastUsedNotebookID: String? {
        defaults.string(forKey: Self.lastUsedKey)
    }

    /// The notebook Add just filed into, or none, which the next share opens on.
    func rememberLastUsed(_ notebookID: String?) {
        if let notebookID {
            guard defaults.string(forKey: Self.lastUsedKey) != notebookID else { return }
            defaults.set(notebookID, forKey: Self.lastUsedKey)
        } else if defaults.object(forKey: Self.lastUsedKey) != nil {
            defaults.removeObject(forKey: Self.lastUsedKey)
        }
    }
}

/// What the share sheet shows of a shared item, read from what the sending app
/// handed over: no fetch.
enum MobileSharePreview {
    /// An http or https address with a host.
    static func isWebAddress(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// The web address shared text names: the text itself when it is one,
    /// else the first web link in it. Nil for text with no web address.
    static func webAddress(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), isWebAddress(url) { return url }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return detector.matches(in: trimmed, range: range)
            .lazy
            .compactMap(\.url)
            .first(where: isWebAddress)
    }

    /// The site a link is from: its host, without a leading "www.".
    static func site(of url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The title the sending app gave the item: the first line of its title,
    /// else of its text (Safari puts the page's title there), unless that line
    /// is only an address. Nil when it gave none, so the Mac names the source
    /// when it fetches it.
    static func title(itemTitle: String?, contentText: String?) -> String? {
        for candidate in [itemTitle, contentText] {
            guard let line = firstLine(of: candidate) else { continue }
            if let url = URL(string: line), isWebAddress(url) { continue }
            return line
        }
        return nil
    }

    private static func firstLine(of text: String?) -> String? {
        text?
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

/// The notebook adds a drain of the share queue makes: each notebook a shared
/// item was filed into that is still a notebook on this phone, with its
/// captured sources in the order they were shared, each once. An item filed
/// into a notebook gone since stays in the library, where its capture put it.
enum MobileShareFiling {
    struct Add: Equatable, Sendable {
        let notebookID: String
        let sourceIDs: [String]
    }

    static func adds(
        _ captured: [(sourceID: String, notebookID: String)],
        liveNotebookIDs: Set<String>
    ) -> [Add] {
        var order: [String] = []
        var sourcesByNotebook: [String: [String]] = [:]
        for item in captured where liveNotebookIDs.contains(item.notebookID) {
            if sourcesByNotebook[item.notebookID] == nil {
                order.append(item.notebookID)
                sourcesByNotebook[item.notebookID] = []
            }
            guard sourcesByNotebook[item.notebookID]?.contains(item.sourceID) == false else { continue }
            sourcesByNotebook[item.notebookID]?.append(item.sourceID)
        }
        return order.map { Add(notebookID: $0, sourceIDs: sourcesByNotebook[$0] ?? []) }
    }
}
