import Foundation

/// Where this profile keeps the one audio-cache folder that is not shared with
/// the other profile: the per-profile `TTSAudioCache`, home of `ArticleMarkers/`.
///
/// A marker asserts that this profile's library has a finished export in its
/// own iCloud document root, which the production and Dev profiles
/// deliberately do not share. Every other audio cache is content-addressed and
/// lives in the profile-independent folder (`ForeverLMRuntimeIdentity`).
enum SharedDerivedCacheAdoption {
    static var profileTTSAudioCacheURL: URL {
        ForeverLMRuntimeIdentity.applicationSupportRootURL
            .appendingPathComponent("TTSAudioCache", isDirectory: true)
    }
}
