import Foundation
import ImageIO
import SwiftUI
import UIKit

// A notebook's AI-drawn cover on the iPhone (docs/cloudkit-schema-design.md D53, §3.5.6 `files`, §5.9). The
// cover, `Notebook.files.cover`, is drawn by a Mac (`NotebookCoverService`): when
// the learner makes a notebook there, from a claimed `Job(makeDerived, nb:<id>, {derived: "cover"})` for one
// made on the phone or through the hosted MCP, and once for every notebook that has none (the backfill). The
// phone draws nothing itself and never runs the backfill or writes its marker. It shows the cover where it
// drew the title's emoji, bare as the Mac shows it (`NotebookCoverCutout`; docs/notebooks-design.md, "A cover
// is drawn bare"), the emoji while the cover is missing or still arriving, and asks a Mac for a cover when the
// learner makes a notebook here.

/// What the phone says to a Mac about a cover.
enum MobileNotebookCover {
    /// `images.drawNotebookCovers.automatic` (§3.5.3): whether a notebook made one at a time gets a cover
    /// without being asked (false when absent). The phone reads it and never writes it: it is set in
    /// Settings › Images on the Mac and over MCP.
    static let automaticSettingKey = "images.drawNotebookCovers.automatic"
    static let jobKind = "makeDerived"

    /// The Job's `target`, the notebook's item reference (`nb:<id>`).
    static func jobTarget(_ notebookID: String) -> String { "nb:\(notebookID)" }

    /// The Job's `params`: `{derived: "cover"}` alone. A `tool` would send the claiming Mac to that tool's
    /// handler instead of drawing.
    static var jobParams: SyncJSON { .object(["derived": .string("cover")]) }

    /// Whether a cover is drawn without being asked: the Setting on (false when absent).
    static func isWanted(automatic: Bool?) -> Bool {
        automatic ?? false
    }

    /// Whether `fields` (a Notebook's) name a cover.
    static func holdsCover(_ fields: [String: SyncJSON]) -> Bool {
        fields["files"]?["cover"].flatMap(FileRef.init(json:)) != nil
    }
}

// MARK: - Asking a Mac for a cover

extension MobileWrite {
    /// Asks a Mac to draw a notebook's cover (D53): a `Job(makeDerived)` the first Mac to claim runs, once
    /// while it waits. Nothing is written for a notebook that has a cover, one in a space (the space owner's
    /// Mac draws those), or one that is gone. Returns the Job's id, nil when none was needed.
    mutating func requestNotebookCover(_ id: String) throws -> String? {
        let notebook = try liveNotebook(id)
        guard notebook.isPersonal, !MobileNotebookCover.holdsCover(notebook.envelope.fields) else { return nil }
        let target = MobileNotebookCover.jobTarget(notebook.id)
        if let waiting = try jobs().first(where: { job in
            job.fields["kind"]?.stringValue == MobileNotebookCover.jobKind && job.fields["target"]?.stringValue == target
                && job.fields["params"]?["derived"]?.stringValue == "cover"
                && ["queued", "running"].contains(job.fields["status"]?.stringValue ?? "")
        }) {
            return waiting.id
        }
        return try writeJob(MobileNotebookCover.jobKind, target: target, params: MobileNotebookCover.jobParams)
    }
}

extension MobileRecordWriter {
    func requestNotebookCover(_ notebookID: String) async throws -> String? {
        try await transaction { try $0.requestNotebookCover(notebookID) }
    }
}

/// The phone's New notebook asks for the cover of the notebook it just made, once, when covers are drawn
/// without being asked.
enum MobileNotebookCoverRequest {
    /// Writes the cover's Job unless the Setting is off. The Setting is read from the account's row; when it
    /// cannot be read nothing is written, since a stale answer would spend. A notebook the learner did not
    /// make one at a time (an import, a share) never comes here. Returns the Job's id, nil when none was
    /// written.
    @discardableResult
    static func requestIfWanted(
        notebookID: String,
        writer: MobileRecordWriter,
        automatic: () async throws -> Bool?
    ) async -> String? {
        do {
            guard MobileNotebookCover.isWanted(automatic: try await automatic()) else { return nil }
            return try await writer.requestNotebookCover(notebookID)
        } catch {
            // The notebook is made; it keeps its emoji, and a Mac's backfill or Draw Cover With gives it one.
            return nil
        }
    }
}

// MARK: - Reading a cover

extension MobileSatellites {
    /// The satellite of a notebook's cover (`Notebook.files.cover`) from the first zone that holds the
    /// notebook with one, the learner's own `Library` before a space's. Only a notebook the replica's index
    /// says has a cover is decoded, so a list of notebooks costs one query each. Nil when it names none, or
    /// the zone's root is not held yet.
    func notebookCover(_ notebookID: String) async throws -> MobileSatellite? {
        let zones = try await projection.replica.read { replica -> [String] in
            var keys: [String] = []
            try replica.connection.query("""
                SELECT zone_key FROM m_notebooks WHERE id = ? AND has_cover = 1
                ORDER BY CASE WHEN zone_key = ? THEN 0 ELSE 1 END, zone_key
            """, [.text(notebookID), .text(MobileProjection.libraryKey)]) { keys.append($0.text(0) ?? "") }
            return keys
        }
        for zoneKey in zones {
            guard let envelope = try await projection.envelope(.notebook, id: notebookID, zoneKey: zoneKey),
                  let file = Self.file(in: envelope, map: "files", matching: { $0 == "cover" }),
                  let satellite = try await satellite(file, ownerZoneKey: zoneKey) else { continue }
            return satellite
        }
        return nil
    }
}

/// A cover as the phone draws it: the picture, and whether its ground was taken away (`NotebookCoverCutout`,
/// the Mac's own cut). A cover that has no flat ground to take stays as drawn.
final class MobileNotebookCoverPicture {
    let image: UIImage
    let isBare: Bool

    init(image: UIImage, isBare: Bool) {
        self.image = image
        self.isBare = isBare
    }

    /// The picture the stored bytes hold, cut once. Off the main actor: it reads and walks every pixel.
    nonisolated static func make(from data: Data) -> MobileNotebookCoverPicture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let drawn = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return UIImage(data: data).map { MobileNotebookCoverPicture(image: $0, isBare: false) }
        }
        if let bare = NotebookCoverCutout.bare(drawn) {
            return MobileNotebookCoverPicture(image: UIImage(cgImage: bare), isBare: true)
        }
        return MobileNotebookCoverPicture(image: UIImage(cgImage: drawn), isBare: false)
    }
}

/// The covers the phone has drawn as pictures, by the hash of their bytes: content-addressed, so never stale.
/// Each is cut once, off the main actor, and kept with whether it is bare.
@MainActor
final class MobileNotebookCoverImages: ObservableObject {
    static let shared = MobileNotebookCoverImages()

    private let pictures = NSCache<NSString, MobileNotebookCoverPicture>()
    private var reads: [String: Task<MobileNotebookCoverPicture?, Never>] = [:]
    /// Moves when the replica changed, at most once per interval: every icon on screen asks again for its
    /// notebook's cover then. One observer here, not one per icon, which a scroll position saved every few
    /// seconds made a query each.
    @Published private(set) var revision = 0
    private var changes: MobileReloadCoalescer?
    private var observer: NSObjectProtocol?

    init() {
        changes = MobileReloadCoalescer { [weak self] in self?.revision &+= 1 }
        observer = NotificationCenter.default.addObserver(forName: .mobileReplicaDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.changes?.changed() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The notebook's cover; nil for none, and until its bytes are here (offline, not
    /// uploaded yet): the caller shows the emoji, and asks again when the replica changes.
    func picture(forNotebook notebookID: String) async -> MobileNotebookCoverPicture? {
        guard let satellites = await MobileSatellites.current() else { return nil }
        return await picture(forNotebook: notebookID, satellites: satellites)
    }

    func picture(forNotebook notebookID: String, satellites: MobileSatellites) async -> MobileNotebookCoverPicture? {
        guard let cover = try? await satellites.notebookCover(notebookID) else { return nil }
        let hash = cover.file.hash
        if let held = pictures.object(forKey: hash as NSString) { return held }
        if let running = reads[hash] { return await running.value }
        let read = Task { () -> MobileNotebookCoverPicture? in
            guard let data = try? await satellites.data(cover) else { return nil }
            return await Task.detached(priority: .utility) { MobileNotebookCoverPicture.make(from: data) }.value
        }
        reads[hash] = read
        let picture = await read.value
        reads[hash] = nil
        if let picture { pictures.setObject(picture, forKey: hash as NSString) }
        return picture
    }
}

/// A notebook's icon wherever it is drawn as a picture: its cover once the phone holds one, the emoji
/// (`fallback`) while the cover is missing or still arriving. Menus and sentences, which are text, keep the
/// emoji and never use this.
///
/// A cover is drawn bare, as the Mac's `NotebookIconView` draws it: the icon alone, as large as `size`, with
/// no tile behind it, and in dark mode on a light plate, since its strokes are dark. One with no flat ground
/// to take away is drawn as it was made, filling a rounded square or a circle.
struct MobileNotebookIconView<Fallback: View>: View {
    let notebookID: String
    /// The picture's side in points: the frame the emoji sits in at its place.
    let size: CGFloat
    /// The picture's corner radius; nil for a circle.
    var cornerRadius: CGFloat?
    /// The tile the emoji sits on while there is no cover, such as the notebook's colour. A cover
    /// never sits on it.
    var plate: Color?
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.colorScheme) private var colorScheme
    @State private var cover: MobileNotebookCoverPicture?
    @ObservedObject private var covers = MobileNotebookCoverImages.shared

    private struct Ask: Hashable {
        let notebookID: String
        let revision: Int
    }

    private var shape: AnyShape {
        cornerRadius.map { AnyShape(RoundedRectangle(cornerRadius: $0, style: .continuous)) } ?? AnyShape(Circle())
    }

    var body: some View {
        Group {
            if let cover {
                if cover.isBare {
                    bare(cover.image)
                } else {
                    Image(uiImage: cover.image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(shape)
                }
            } else if let plate {
                fallback()
                    .frame(width: size, height: size)
                    .background(plate, in: shape)
            } else {
                fallback()
            }
        }
        .task(id: Ask(notebookID: notebookID, revision: covers.revision)) { await refresh() }
    }

    /// The icon alone. In dark mode its dark strokes would sink into the screen, so it sits on a light
    /// plate there. A circle (a token on its notebook's colour, a collection's stack) holds it inside, so
    /// its corners are not cut off.
    @ViewBuilder
    private func bare(_ image: UIImage) -> some View {
        let plated = colorScheme == .dark
        let inset = cornerRadius == nil ? size * 0.17 : (plated ? size * 0.1 : 0)
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .padding(inset)
            .frame(width: size, height: size)
            .background {
                if plated { shape.fill(Color(uiColor: UIColor(white: 0.94, alpha: 1))) }
            }
    }

    private func refresh() async {
        let picture = await MobileNotebookCoverImages.shared.picture(forNotebook: notebookID)
        if picture !== cover { cover = picture }
    }
}
