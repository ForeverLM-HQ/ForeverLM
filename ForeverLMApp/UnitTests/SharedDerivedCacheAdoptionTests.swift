import Foundation
import Testing
@testable import ForeverLM

@Suite("Shared derived cache location")
struct SharedDerivedCacheLocationTests {
    @Test("The shared cache root is the same folder for both profiles")
    func sharedRootIsProfileIndependent() {
        // The whole point: production and Dev resolve to one directory, while
        // everything that carries identity stays split.
        let production = ForeverLMRuntimeIdentity.profile(isDevelopment: false)
        let development = ForeverLMRuntimeIdentity.profile(isDevelopment: true)
        #expect(production.productFolderName != development.productFolderName)

        let shared = ForeverLMRuntimeIdentity.sharedProductFolderName
        #expect(shared != production.productFolderName)
        #expect(shared != development.productFolderName)

        // `sharedTTSAudioCacheURL` reads no profile state, so a single value is
        // what both builds see.
        #expect(
            ForeverLMRuntimeIdentity.sharedTTSAudioCacheURL.path
                == ForeverLMRuntimeIdentity.sharedDerivedCacheRootURL
                    .appendingPathComponent("TTSAudioCache", isDirectory: true).path
        )
        #expect(
            ForeverLMRuntimeIdentity.sharedDerivedCacheRootURL.lastPathComponent == shared
        )
    }

    @Test("The shared folder is not mistaken for a library root")
    func sharedFolderIsNotALibraryRoot() {
        // `StorageService` strips a leading product-folder component off stored
        // content paths. The shared folder holds no content sources, so it must
        // fall outside that pattern — a match would silently eat the first
        // segment of a path that begins with its name.
        let stored = "\(ForeverLMRuntimeIdentity.sharedProductFolderName)/Papers/Example.pdf"
        #expect(StorageService.relativeSourcePath(stored) == stored)

        // The real product folders still normalize, so this is a statement about
        // the shared name and not a regression in the stripper.
        #expect(StorageService.relativeSourcePath("ForeverLM/Papers/Example.pdf") == "Papers/Example.pdf")
        #expect(StorageService.relativeSourcePath("ForeverLM Dev/Papers/Example.pdf") == "Papers/Example.pdf")
    }

    @Test("Voice previews resolve to the shared folder")
    func voicePreviewsAreShared() {
        // Same argument as the TTS cache: the key is a hash of model, voice and
        // the fixed sample text, and the warm-up walks the whole catalog.
        let previews = ForeverLMRuntimeIdentity.sharedVoicePreviewCacheURL.path
        #expect(previews.hasPrefix(ForeverLMRuntimeIdentity.sharedDerivedCacheRootURL.path + "/"))
        #expect(!previews.hasPrefix(ForeverLMRuntimeIdentity.applicationSupportRootURL.path + "/"))

        let model = try? #require(ArticleSpeechCatalog.models.first)
        let voice = model?.voices.first
        if let model, let voice {
            let file = ArticleSpeechVoicePreviewRepository.fileURL(modelID: model.id, voiceID: voice.id)
            #expect(file.deletingLastPathComponent().path == previews)
        }
    }

    @Test("Article markers stay under the per-profile folder")
    func markersRemainPerProfile() {
        // Markers assert that this profile's iCloud document root holds a
        // finished export. The two roots are separate by design, so a shared
        // marker would be a false positive.
        let markers = ArticleSpeechAudioCache.markerDirectory().path
        #expect(markers.hasPrefix(ForeverLMRuntimeIdentity.applicationSupportRootURL.path + "/"))
        #expect(!markers.hasPrefix(ForeverLMRuntimeIdentity.sharedDerivedCacheRootURL.path + "/"))
        #expect(markers.hasSuffix("/TTSAudioCache/ArticleMarkers"))
    }
}
