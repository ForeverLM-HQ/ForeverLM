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
        static let generateIcons = AccountKey<Bool?>("images.generateIcons")
        static let generateIconsAutomatic = AccountKey<Bool?>("images.generateIcons.automatic")
        static let drawQuizPicturesAutomatic = AccountKey<Bool>("images.drawQuizPictures.automatic", default: true)
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
