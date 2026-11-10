import Foundation

// A narration as a source's satellites (docs/cloudkit-schema-design.md §3.5.30 `files.audio.<voiceKey>`,
// children `audioChunk`; D29; §14.2 NARR2 and NARR3). The replica holds a narration, not
// iCloud Drive: the manifest is the `audio.<voiceKey>` satellite (`SyncedArticleAudioManifest` as JSON, gzip)
// and each chunk a child satellite of role `audioChunk` keyed by the chunk's file name.
//
// The phone (`MobileNarrationLibrary`) and the Mac (`MacNarrationLibrary`) keep a working folder of the
// layout `SyncedArticleAudioStore` has always used and reconcile it with the replica by one table
// (`NarrationPlan`), so a narration made on either plays on the other. What both must agree on lives here:
// the satellites' names, the plan, and what a working folder says about a narration.

/// What a narration's satellites are called.
enum NarrationSatellites {
    static let rolePrefix = "audio."
    static let chunkRole = "audioChunk"

    /// `audio.<model>.<voice>`: the voice key is the two ids lower-cased with every other character a
    /// dash, so it is safe inside a satellite's name. A model with no voice list reads "default".
    static func role(model: String, voice: String) -> String {
        "\(rolePrefix)\(slug(model)).\(slug(voice))"
    }

    static func slug(_ text: String) -> String {
        var result = ""
        for scalar in text.lowercased().unicodeScalars {
            let keep = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
            let next: Character = keep ? Character(scalar) : "-"
            if next == "-", result.last == "-" || result.isEmpty { continue }
            result.append(next)
        }
        while result.last == "-" { result.removeLast() }
        return result.isEmpty ? "default" : result
    }

    static func chunkMime(fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }

    /// Whether a `files` role is a narration's.
    static func isNarrationRole(_ role: String) -> Bool { role.hasPrefix(rolePrefix) }
}

extension FileRef {
    /// What a child satellite stands for inside its parent (a narration chunk's file name, a walk
    /// picture's image id), which the writer puts beside the FileRef's own fields.
    var key: String? { value["key"]?.stringValue }

    /// The same FileRef filed under its parent as the child a writer keyed `key` (§3.5.30).
    func keyed(_ key: String) -> FileRef {
        var object = json
        object["key"] = .string(key)
        return FileRef(json: .object(object)) ?? self
    }
}

extension NarrationSatellites {
    /// A narration's chunks as the children its FileRef lists: each of the manifest's chunks, in its order,
    /// is the child keyed by its file name (compared without case), else the child at its place when that
    /// one carries no key. Nil where the FileRef lists none for a chunk.
    static func children(of narration: FileRef, manifest: SyncedArticleAudioManifest) -> [FileRef?] {
        let children = narration.children.filter { $0.role == chunkRole }
        return manifest.chunks.enumerated().map { place, chunk in
            children.first { $0.key?.caseInsensitiveCompare(chunk.fileName) == .orderedSame }
                ?? (children.indices.contains(place) && children[place].key == nil ? children[place] : nil)
        }
    }
}

/// What a working folder holds of a narration, what the replica holds, and what to do about it.
struct NarrationLocal: Equatable, Sendable {
    /// sha-256 of the manifest file, which is the manifest satellite's `hash` once it is uploaded.
    var hash: String
    /// Every chunk the manifest names is on disk. A narration already known to be in step with the replica
    /// (its pointer names this hash) is not checked: nothing asks.
    var complete: Bool
    var createdAt: Date
    /// The manifest hash last seen to match the replica (uploaded here, or laid down from it); nil for a
    /// narration made here that was never in step with the replica.
    var pointer: String?
}

struct NarrationReplica: Equatable, Sendable {
    /// This device holds the source's record, so its silence about audio means something.
    var held: Bool
    /// The `hash` of the manifest satellite the source names.
    var hash: String?
}

enum NarrationAction: Equatable, Sendable {
    case none
    /// In step already; remember that.
    case record
    /// Made here, not yet in the replica: upload it.
    case publish
    /// The replica's narration replaces what the folder holds, or fills an empty folder.
    case mirror
    /// The replica dropped the narration this folder mirrored: drop it here too.
    case remove
    /// Made here and different from the replica's, never in step: the newer one wins.
    case compare
}

enum NarrationPlan {
    static func action(local: NarrationLocal?, replica: NarrationReplica) -> NarrationAction {
        guard let local else { return replica.hash == nil ? .none : .mirror }
        guard replica.held else { return .none }
        guard let remote = replica.hash else {
            if local.pointer != nil { return .remove }
            return local.complete ? .publish : .none
        }
        if remote == local.hash { return local.pointer == remote ? .none : .record }
        return local.pointer == local.hash ? .mirror : .compare
    }
}

/// The working folder's own bookkeeping: what a manifest file says, and the note kept beside it of the last
/// hash seen in step with the replica (`satellite.json`).
enum NarrationFolder {
    static let pointerFileName = "satellite.json"

    /// What the folder holds of every narration it has, by source: one read of each manifest file (its
    /// hash), and a decode only for one not known to be in step with the replica.
    static func localStates() -> [String: NarrationLocal] {
        let audio = SyncedArticleAudioStore.audioRootURL()
        var found: [String: NarrationLocal] = [:]
        for directory in (try? FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            if let (id, state) = localState(in: directory) { found[id] = state }
        }
        return found
    }

    static func localState(sourceID: String) -> NarrationLocal? {
        localState(in: SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)).flatMap { $0.id == sourceID ? $0.state : nil }
    }

    private static func localState(in directory: URL) -> (id: String, state: NarrationLocal)? {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent(SyncedArticleAudioStore.manifestFileName), options: .mappedIfSafe) else { return nil }
        let hash = SyncIdentity.sha256Hex(bytes)
        let pointer = readPointer(in: directory)
        if let pointer, pointer.hash == hash {
            return (pointer.sourceID, NarrationLocal(hash: hash, complete: true, createdAt: .distantPast, pointer: hash))
        }
        guard let manifest = decode(bytes), manifest.usesSupportedPlaybackFormat else { return nil }
        return (manifest.sourceID, NarrationLocal(
            hash: hash, complete: SyncedArticleAudioStore.hasLocalChunks(for: manifest), createdAt: manifest.createdAt, pointer: pointer?.hash
        ))
    }

    static func decode(_ bytes: Data) -> SyncedArticleAudioManifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SyncedArticleAudioManifest.self, from: bytes)
    }

    private static func readPointer(in directory: URL) -> (hash: String, sourceID: String)? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(pointerFileName)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let hash = object["hash"], let sourceID = object["sourceID"] else { return nil }
        return (hash, sourceID)
    }

    static func readPointer(sourceID: String) -> String? {
        readPointer(in: SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)).flatMap { $0.sourceID == sourceID ? $0.hash : nil }
    }

    static func writePointer(_ hash: String, sourceID: String) {
        let directory = SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)
        guard let data = try? JSONSerialization.data(withJSONObject: ["hash": hash, "sourceID": sourceID], options: [.sortedKeys]),
              (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
        try? data.write(to: directory.appendingPathComponent(pointerFileName), options: .atomic)
    }

    /// Lays a manifest the replica names into the folder as the file the audio store reads, and remembers it is
    /// in step. The chunks themselves wait until something plays them. A manifest that replaces another takes
    /// the old narration's chunks and text with it: every narration numbers its chunks `chunk-0000.mp3` on, so a
    /// file the new manifest names by the same name would otherwise play the old audio. Returns false for bytes
    /// that are not the manifest of `sourceID`.
    @discardableResult
    static func lay(manifest bytes: Data, sourceID: String) throws -> Bool {
        guard let manifest = decode(bytes), manifest.sourceID == sourceID else { return false }
        let directory = SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)
        let manifestURL = SyncedArticleAudioStore.manifestURL(sourceID: sourceID)
        if let held = try? Data(contentsOf: manifestURL), SyncIdentity.sha256Hex(held) != SyncIdentity.sha256Hex(bytes) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true))
            let text = (decode(held)?.sourceTextFileName ?? SyncedArticleAudioStore.sourceTextFileName) as NSString
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(text.lastPathComponent))
        } else {
            let chunks = directory.appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
            let named = Set(manifest.chunks.map(\.fileName))
            for stale in (try? FileManager.default.contentsOfDirectory(atPath: chunks.path)) ?? [] where !named.contains(stale) {
                try? FileManager.default.removeItem(at: chunks.appendingPathComponent(stale))
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: SyncedArticleAudioStore.manifestURL(sourceID: sourceID), options: .atomic)
        writePointer(SyncIdentity.sha256Hex(bytes), sourceID: sourceID)
        return true
    }

    /// A chunk file in its place in the folder: a hard link when the volume allows, else a copy.
    static func place(_ source: URL, at destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        do {
            try manager.linkItem(at: source, to: destination)
        } catch {
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).part")
            try? manager.removeItem(at: staged)
            try manager.copyItem(at: source, to: staged)
            try manager.moveItem(at: staged, to: destination)
        }
    }

    /// Bytes as a chunk file in its place in the folder, written whole or not at all.
    static func place(_ bytes: Data, at destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination, options: .atomic)
    }
}
