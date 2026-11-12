import Foundation

/// The roomy screen's notebook and Home as the Mac draws them
/// (docs/notebooks-design.md, "iPhone", the iPad and iPhone Duo paragraphs): a
/// notebook as Gemini Notebook's three parts side by side — **Sources** on the
/// left, the chat in the middle, **Studio** on the right, each side folding to
/// a strip — and Home's notebooks as the Mac's gallery of cards. The numbers
/// are the Mac's (`NotebookWorkspaceSizing`), with a wider side minimum for
/// touch rows. A screen is roomy by its size classes and its width, never by
/// the device it is: an iPad, a resized window and an iPhone Duo's open inner
/// display (regular both ways) are the same case, and the Duo's outer display
/// is a phone's. Pure, so the rule the screens lay out by is tested without a
/// view.
enum MobileNotebookColumnLayout {
    /// A side column, which folds to its strip.
    enum Side: String, CaseIterable, Sendable {
        case sources
        case studio
    }

    /// A side column's narrowest and widest while open. The Mac's 260 is a
    /// pointer's column; a touch row with its 44-point box needs a little more.
    static let sideMinimumWidth: CGFloat = 280
    static let sideMaximumWidth: CGFloat = 360
    /// Each side column's share of the width: the Mac's
    /// (`NotebookWorkspaceSizing.sideShare`), Gemini's quarter, a little less.
    static let sideShare: CGFloat = 0.24
    /// A folded side column: the Mac's and Gemini's 56-point strip, a
    /// 44-point button with room around it.
    static let stripWidth: CGFloat = 56
    /// The chat's narrowest: the Mac's `minimumChatContentWidth`.
    static let chatMinimumWidth: CGFloat = 360
    static let separatorWidth: CGFloat = 1

    /// The narrowest notebook the three columns are drawn in: both sides open
    /// at their narrowest and the chat at its own, 922 points. Every iPad in
    /// landscape, a 13-inch iPad in portrait and an iPhone Duo's inner display
    /// turned wide; an 11-inch iPad or an iPad mini in portrait, the inner
    /// display held tall, and Split View, keep the tab bar. Folding a side
    /// never moves the line, so the layout never changes under a tap.
    static var minimumWidth: CGFloat {
        sideMinimumWidth * 2 + chatMinimumWidth + separatorWidth * 2
    }

    /// Whether a notebook `width` points wide draws its columns rather than
    /// its tab bar: a screen in regular width **and** regular height with the
    /// room for all three. Height is what keeps a large phone in landscape on
    /// its tabs (regular width, compact height, a notebook under 440 points
    /// tall), as the Duo's outer display and its closed landscape are
    /// (compact both ways); the open inner display is regular both ways in
    /// either turn, so it joins the iPad.
    static func usesColumns(isRegularWidth: Bool, isRegularHeight: Bool, width: CGFloat) -> Bool {
        isRegularWidth && isRegularHeight && width >= minimumWidth
    }

    /// An open side column's width in a notebook `totalWidth` wide: its share,
    /// within the two bounds.
    static func sideWidth(totalWidth: CGFloat) -> CGFloat {
        min(max(totalWidth * sideShare, sideMinimumWidth), sideMaximumWidth)
    }

    /// A side column's width, open or folded to its strip.
    static func width(folded: Bool, totalWidth: CGFloat) -> CGFloat {
        folded ? stripWidth : sideWidth(totalWidth: totalWidth)
    }

    /// Where this device remembers a side folded: one value for every
    /// notebook, on this device only. A fold is how this screen is laid out,
    /// not something about the notebook, so it is never a synced row.
    static func foldedKey(_ side: Side) -> DeviceKey<Bool> {
        Prefs.Families.notebookColumnFolded.key("\(side.rawValue)Folded")
    }

    static func foldedDefaultsKey(_ side: Side) -> String {
        foldedKey(side).name
    }

    // MARK: - Home

    /// Whether Home lists its notebooks as the Mac's gallery of cards: a
    /// screen in regular width and regular height. A phone, in either turn
    /// and however wide, keeps the list; so does the Duo closed.
    static func usesGallery(isRegularWidth: Bool, isRegularHeight: Bool) -> Bool {
        isRegularWidth && isRegularHeight
    }

    /// A gallery card's narrowest and widest, and the gap between cards.
    static let galleryCardMinimumWidth: CGFloat = 220
    static let galleryCardMaximumWidth: CGFloat = 300
    static let galleryCardSpacing: CGFloat = 16
    /// A card's narrowest on a phone's Notebooks screen in Grid: two to a
    /// row on every iPhone in portrait (`MobileNotebookGalleryCard.isCompact`).
    static let compactGalleryCardMinimumWidth: CGFloat = 150
}
