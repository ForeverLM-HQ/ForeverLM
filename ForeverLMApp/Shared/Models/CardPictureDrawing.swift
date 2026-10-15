import Foundation

/// A picture drawn for one card to check, when the learner asks for one
/// (product owner, 2026-10-15, on a card from a podcast: "this could use an
/// image"). A source with figures gets them pinned by the drafter
/// (`CardDraftingPictures`); a podcast or an article prints none, so To Check's
/// ••• has **Draw Picture**, which draws one diagram of the card's answer on
/// the image model of Settings › Images. It is one paid image request and only
/// ever runs when asked. The picture sits with the answer, so it may show it,
/// and is kept on the card only when the learner keeps the card.
enum CardPictureDrawing {
    /// The passage of the source quoted to the image model is cut here: the
    /// picture is of the idea, and a long passage only crowds it.
    static let maximumPassageCharacters = 700

    /// What the image model is asked for: a teaching diagram of the card's
    /// answer, in the quiz pictures' house style, drawn only from the card and
    /// the passage it stands on.
    static func prompt(card: MemoryCard, sourceTitle: String?, passage: String?) -> String {
        var lines: [String] = []
        let source = sourceTitle.map { " drawn from \"\($0)\"" } ?? ""
        lines.append("A teaching picture for one flashcard\(source).")
        lines.append("The question: \(card.front)")
        lines.append("The answer: \(card.back)")
        if !card.why.isEmpty { lines.append("Why it holds: \(card.why.joined(separator: " "))") }
        if let passage = clipped(passage) { lines.append("The passage it stands on: \(passage)") }
        lines.append("The learner sees the picture together with the answer, so it shows the answer: the one idea the answer states, what is drawn and how its parts relate.")
        lines.append("Style: a clear scientific diagram on a plain white background, flat colours, clean outlines. Label only the few parts the answer names, in a few short words each, spelled exactly; no titles, captions, paragraphs or equations. Nothing decorative, no scenery, no people unless the answer is about them. Invent no data: no plotted values, axes with numbers or measurements the card does not give.")
        return lines.joined(separator: "\n")
    }

    /// The card's picture as a card face keeps it: the stored drawing's
    /// address and a few words of what it shows.
    static func image(storedID: String, card: MemoryCard) -> MemoryCardImage? {
        guard let reference = GeneratedImageReference(id: storedID) else { return nil }
        return MemoryCardImage(target: reference.urlString, alt: GeneratedImageStore.altText(card.back))
    }

    private static func clipped(_ passage: String?) -> String? {
        let flat = passage?
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !flat.isEmpty else { return nil }
        guard flat.count > maximumPassageCharacters else { return flat }
        let head = String(flat.prefix(maximumPassageCharacters))
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head[...]
        return String(cut) + "…"
    }
}

extension MemoryCardToCheck {
    /// The card with one more picture on its answer, as drawn for it. A card
    /// whose answer holds the most pictures a face may keep, or that picture
    /// already, is returned as it is.
    func addingBackImage(_ image: MemoryCardImage) -> MemoryCardToCheck {
        guard face.backImages.count < MemoryCard.maximumImagesPerFace,
              !face.backImages.contains(image) else { return self }
        return replacingImages(back: face.backImages + [image])
    }

    /// The card with the pictures of a face replaced, as `update_card` replaces
    /// them on a kept card: a nil side keeps the pictures it has, an empty one
    /// takes them off. A face keeps at most `MemoryCard.maximumImagesPerFace`; the card cuts a longer list there.
    func replacingImages(front: [MemoryCardImage]? = nil, back: [MemoryCardImage]? = nil) -> MemoryCardToCheck {
        var card = MemoryCardToCheck(
            kind: kind,
            face: MemoryCard(
                cardID: face.cardID,
                front: face.front,
                back: face.back,
                why: face.why,
                origin: face.origin,
                deckID: face.deckID,
                frontImages: front ?? face.frontImages,
                backImages: back ?? face.backImages
            ),
            deckID: deckID,
            sourceID: sourceID,
            quote: quote,
            seed: seed,
            ideaID: ideaID,
            draftedAt: draftedAt,
            isRequested: isRequested,
            memoryItemID: memoryItemID
        )
        card.alsoFrom = alsoFrom
        return card
    }
}
