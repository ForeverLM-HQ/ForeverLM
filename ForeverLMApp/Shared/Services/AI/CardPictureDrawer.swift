#if os(macOS)
import Foundation

/// Draws the picture of a card to check (`CardPictureDrawing`): one image
/// request on `model`, kept in the image store as a compact JPEG with its
/// prompt, as a quiz's drawing is. Nothing is written to the card here; the
/// learner's Keep carries the picture.
enum CardPictureDrawer {
    static func draw(
        _ card: MemoryCardToCheck,
        sourceTitle: String?,
        passage: String?,
        model: ImageGenerationModel
    ) async throws -> MemoryCardImage {
        let prompt = CardPictureDrawing.prompt(card: card.face, sourceTitle: sourceTitle, passage: passage)
        let generated = try await ManagedImageGeneration.generate(
            prompt: prompt,
            model: model,
            shape: .landscape,
            quality: .medium,
            usageTask: "card_picture",
            source: AIUsageSource(id: card.sourceID, type: "source", title: sourceTitle ?? card.sourceID)
        )
        let modelName = model.name
        let modelID = model.id
        let title = GeneratedImageStore.altText(card.face.front)
        let stored = try await Task.detached(priority: .utility) {
            try GeneratedImageStore.store(
                CourseQuizGeneratorService.compactDrawing(generated),
                origin: .drawn,
                text: prompt,
                title: title,
                model: modelName,
                modelID: modelID,
                revising: nil
            )
        }.value
        guard let image = CardPictureDrawing.image(storedID: stored.id, card: card.face) else {
            throw ManagedImageGeneration.Failure.noImageReturned
        }
        return image
    }
}
#endif
