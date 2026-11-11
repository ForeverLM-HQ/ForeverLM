import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// Generated pictures and video.
    enum Imaging {
        /// Generated imagery. The model is a spending decision like the voices
        /// above, and Web Studio draws with it too, so it has to follow the
        /// account rather than the Mac it was picked on. Keys owned by
        /// `MacImageGenerationSettings`.
        static let imageModel = AccountKey<String?>("images.model")
        static let imageStyle = AccountKey<String?>("images.style")
        static let imageSource = AccountKey<String?>("images.source")
        /// Whether ForeverLM may pay to draw anything at all. Off until asked for:
        /// every other way a source gets its thumbnail is free, and this one is not.
        static let generateIcons = AccountKey<Bool?>("images.generateIcons")
        /// Whether a meeting imported from now on gets an icon without being asked.
        /// Meaningless while `generateIcons` is false.
        static let generateIconsAutomatic = AccountKey<Bool?>("images.generateIcons.automatic")
        /// Whether a course quiz gets its picture as soon as it is written.
        /// Independent of `generateIcons`, which governs meeting icons; a quiz's
        /// picture was always drawn on the learner's request, and writing the
        /// quiz is that request.
        static let drawQuizPicturesAutomatic = AccountKey<Bool>("images.drawQuizPictures.automatic", default: true)
        /// Whether a notebook made one at a time gets its cover drawn without
        /// being asked, and whether the one-time cover backfill runs. Generation 2
        /// only: generation 1 has no cover to write.
        static let drawNotebookCoversAutomatic = AccountKey<Bool>("images.drawNotebookCovers.automatic", default: false, .generation2Only)
        /// Generated video: the model and resolution a film is made at, a
        /// spending decision like the image model above. Keys owned by
        /// `MacVideoGenerationSettings`.
        static let videoModel = AccountKey<String?>("videos.model")
        static let videoResolution = AccountKey<String?>("videos.resolution")

        static let all: [AnyPreferenceKey] = [
            imageModel.erased,
            imageStyle.erased,
            imageSource.erased,
            generateIcons.erased,
            generateIconsAutomatic.erased,
            drawQuizPicturesAutomatic.erased,
            drawNotebookCoversAutomatic.erased,
            videoModel.erased,
            videoResolution.erased,
        ]
    }
}
