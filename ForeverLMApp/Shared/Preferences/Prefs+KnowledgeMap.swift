import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// The canvas.
    enum KnowledgeMap {
        static let showsLibrary = DeviceKey<Bool?>("knowledgeMap.library.v1", reason: "view state of this Mac's canvas")
        static let showsMinimap = DeviceKey<Bool?>("knowledgeMap.minimap.v1", reason: "view state of this Mac's canvas")
        static let openCanvasID = DeviceKey<String?>("knowledgeMap.openCanvasID", reason: "the canvas this Mac last had open")
        static let summaryCache = DeviceKey<Data?>("knowledgeMap.summaryCache.v1", reason: "cache of generated summaries, rebuilt on demand")
        static let writtenFacesEnabled = DeviceKey<Bool?>("knowledgeMap.writtenFaces.enabled", reason: "whether this Mac's canvas writes card faces; never listed as synced")
        static let memoryLayer = DeviceKey<Bool>("knowledgeMap.memoryLayer.v1", default: false, reason: "whether this Mac's canvas shows the Memory layer; a view choice")

        static let all: [AnyPreferenceKey] = [
            showsLibrary.erased,
            showsMinimap.erased,
            openCanvasID.erased,
            summaryCache.erased,
            writtenFacesEnabled.erased,
            memoryLayer.erased,
        ]
    }
}
