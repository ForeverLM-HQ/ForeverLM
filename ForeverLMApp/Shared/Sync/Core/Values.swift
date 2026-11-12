import CryptoKit
import Foundation

// The shared value shapes of §3.3. Each object shape keeps the raw JSON object it was read from
// and reads its keys from it, so a key this build does not know survives a read and a write back
// (§6.5). Vectors: `schema/vectors/locator.json`.

/// A CloudKit user in a space: `{"user": "<user record name>", "name": "<display name>"}`.
struct SyncPerson: Equatable, Sendable {
    private(set) var json: [String: SyncJSON]

    init(user: String, name: String) {
        json = ["user": .string(user), "name": .string(name)]
    }

    init?(json value: SyncJSON) {
        guard let object = value.objectValue, let user = object["user"]?.stringValue, !user.isEmpty else { return nil }
        json = object
    }

    var user: String { json["user"]?.stringValue ?? "" }
    var name: String? { json["name"]?.stringValue }
    var value: SyncJSON { .object(json) }
}

/// `"<kind>:<id>"` with an optional `#<subKey>`, such as `src:src_2cd9#idea-17` or `qz:cq-1913#q3`.
///
/// The sub-key is what follows the first `#`, except for card and work-key references, whose ids
/// carry `#` themselves (`card:<deck>:walk:<src>#q3`, `podcast:<feed>#<guid>`): those, and kinds
/// this build does not know, keep everything after the colon as the id.
struct ItemRef: Hashable, Sendable, CustomStringConvertible {
    enum Kind: Hashable, Sendable {
        case source, collection, notebook, goal, course, lesson, quiz, chat, exchange, artifact, card, workKey, all
        case unknown(String)

        init(rawValue: String) {
            switch rawValue {
            case "src": self = .source
            case "col": self = .collection
            case "nb": self = .notebook
            case "gl": self = .goal
            case "crs": self = .course
            case "les": self = .lesson
            case "qz": self = .quiz
            case "cht": self = .chat
            case "exc": self = .exchange
            case "art": self = .artifact
            case "crd": self = .card
            case "wk": self = .workKey
            case "all": self = .all
            default: self = .unknown(rawValue)
            }
        }

        var rawValue: String {
            switch self {
            case .source: return "src"
            case .collection: return "col"
            case .notebook: return "nb"
            case .goal: return "gl"
            case .course: return "crs"
            case .lesson: return "les"
            case .quiz: return "qz"
            case .chat: return "cht"
            case .exchange: return "exc"
            case .artifact: return "art"
            case .card: return "crd"
            case .workKey: return "wk"
            case .all: return "all"
            case .unknown(let raw): return raw
            }
        }

        fileprivate var takesSubKey: Bool {
            switch self {
            case .card, .workKey, .unknown: return false
            default: return true
            }
        }
    }

    let kind: Kind
    let id: String
    let subKey: String?

    init(_ kind: Kind, _ id: String, subKey: String? = nil) {
        self.kind = kind
        self.id = id
        self.subKey = subKey
    }

    init?(_ text: String) {
        if text == "all" {
            self.init(.all, "")
            return
        }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let kind = Kind(rawValue: String(text[..<colon]))
        let rest = String(text[text.index(after: colon)...])
        if kind.takesSubKey, let hash = rest.firstIndex(of: "#") {
            let id = String(rest[..<hash])
            guard !id.isEmpty else { return nil }
            self.init(kind, id, subKey: String(rest[rest.index(after: hash)...]))
        } else {
            guard !rest.isEmpty else { return nil }
            self.init(kind, rest)
        }
    }

    var rawValue: String {
        if kind == .all, id.isEmpty { return "all" }
        return kind.rawValue + ":" + id + (subKey.map { "#" + $0 } ?? "")
    }

    var description: String { rawValue }
}

/// A place in a source or Doc: `{"t": "pdf"|"text"|"epub"|"media"|"web"|"slide"|"doc", …}`. PDF quads
/// are page-normalized 0…1 with the origin top-left. A kind this build does not know is kept raw.
struct Locator: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case pdf, text, epub, media, web, slide, doc
        case unknown(String)

        init(rawValue: String) {
            switch rawValue {
            case "pdf": self = .pdf
            case "text": self = .text
            case "epub": self = .epub
            case "media": self = .media
            case "web": self = .web
            case "slide": self = .slide
            case "doc": self = .doc
            default: self = .unknown(rawValue)
            }
        }

        var rawValue: String {
            switch self {
            case .pdf: return "pdf"
            case .text: return "text"
            case .epub: return "epub"
            case .media: return "media"
            case .web: return "web"
            case .slide: return "slide"
            case .doc: return "doc"
            case .unknown(let raw): return raw
            }
        }
    }

    private(set) var json: [String: SyncJSON]

    init(_ kind: Kind, _ fields: [String: SyncJSON]) {
        var object = fields
        object["t"] = .string(kind.rawValue)
        json = object
    }

    init?(json value: SyncJSON) {
        guard let object = value.objectValue, object["t"]?.stringValue != nil else { return nil }
        json = object
    }

    var kind: Kind { Kind(rawValue: json["t"]?.stringValue ?? "") }
    var value: SyncJSON { .object(json) }
    subscript(key: String) -> SyncJSON? { json[key] }

    /// The rules the spec states: a PDF quad is 8 numbers, each within 0…1.
    var isValid: Bool {
        guard kind == .pdf, let quads = json["quads"] else { return true }
        guard let list = quads.arrayValue else { return false }
        return list.allSatisfy { quad in
            guard let numbers = quad.arrayValue, numbers.count == 8 else { return false }
            return numbers.allSatisfy { ($0.numberValue).map { (0...1).contains($0) } ?? false }
        }
    }
}

/// The shape `Span`, a lesson item's range of a source, `{"from": Locator, "to": Locator}`: pages
/// 12–40, 00:10–00:45. (Named so it does not shadow the standard library's `Span`.)
struct LocatorSpan: Equatable, Sendable {
    private(set) var json: [String: SyncJSON]

    init(from: Locator, to: Locator) {
        json = ["from": from.value, "to": to.value]
    }

    init?(json value: SyncJSON) {
        guard let object = value.objectValue,
              object["from"].flatMap(Locator.init(json:)) != nil,
              object["to"].flatMap(Locator.init(json:)) != nil
        else { return nil }
        json = object
    }

    var from: Locator { json["from"].flatMap(Locator.init(json:))! }
    var to: Locator { json["to"].flatMap(Locator.init(json:))! }
    var value: SyncJSON { .object(json) }

    /// Both ends valid and of one kind.
    var isValid: Bool { from.isValid && to.isValid && from.kind == to.kind }
}

/// Where a write was made (`{"spaceID"?, "notebookID"?, "courseID"?, "lessonID"?, "chatID"?}`):
/// provenance only, it never forks state.
struct ReaderContext: Equatable, Sendable {
    private(set) var json: [String: SyncJSON]

    init(spaceID: String? = nil, notebookID: String? = nil, courseID: String? = nil, lessonID: String? = nil, chatID: String? = nil) {
        var object: [String: SyncJSON] = [:]
        for (key, value) in [("spaceID", spaceID), ("notebookID", notebookID), ("courseID", courseID), ("lessonID", lessonID), ("chatID", chatID)] {
            if let value { object[key] = .string(value) }
        }
        json = object
    }

    init?(json value: SyncJSON) {
        guard let object = value.objectValue else { return nil }
        json = object
    }

    var spaceID: String? { json["spaceID"]?.stringValue }
    var notebookID: String? { json["notebookID"]?.stringValue }
    var courseID: String? { json["courseID"]?.stringValue }
    var lessonID: String? { json["lessonID"]?.stringValue }
    var chatID: String? { json["chatID"]?.stringValue }
    var value: SyncJSON { .object(json) }
}

/// Provenance of a record: `{"route", "device", "at", "model"?, "chatID"?}`.
struct MadeBy: Equatable, Sendable {
    private(set) var json: [String: SyncJSON]

    init(route: String, device: String, at milliseconds: Int64, model: String? = nil, chatID: String? = nil) {
        var object: [String: SyncJSON] = ["route": .string(route), "device": .string(device), "at": SyncJSON(milliseconds)]
        if let model { object["model"] = .string(model) }
        if let chatID { object["chatID"] = .string(chatID) }
        json = object
    }

    init?(json value: SyncJSON) {
        guard let object = value.objectValue, object["route"]?.stringValue != nil else { return nil }
        json = object
    }

    var route: String { json["route"]?.stringValue ?? "" }
    var device: String? { json["device"]?.stringValue }
    var at: Int64? { json["at"]?.int64Value }
    var model: String? { json["model"]?.stringValue }
    var chatID: String? { json["chatID"]?.stringValue }
    var value: SyncJSON { .object(json) }
}

/// A pointer to immutable `Content` satellites (§3.3, §3.5.30): every satellite's logical id,
/// `ct:<owner>:<role>:<partHash32>`, follows from `owner`, `role` and one entry of `parts`, the
/// first 32 hex characters of the sha256 of that part's **stored** bytes (after gzip when
/// `enc` is gzip). `hash` and `size` describe the decoded file. A copy of a FileRef into another
/// record keeps it verbatim, owner included (D41), so its names stay valid.
struct FileRef: Equatable, Sendable {
    private(set) var json: [String: SyncJSON]

    /// The FileRef of a body already split into stored parts (all but the last of `partSize`).
    init(owner: String, role: String, hash: String, size: Int64, mime: String, encoding: String,
         storedParts: [Data], children: [FileRef] = [], heldBy: String? = nil) {
        precondition(!storedParts.isEmpty, "a FileRef names at least one part")
        let stored = storedParts.reduce(0) { $0 + $1.count }
        var object: [String: SyncJSON] = [
            "owner": .string(owner), "role": .string(role), "hash": .string(hash), "size": SyncJSON(size),
            "mime": .string(mime), "enc": .string(encoding), "stored": SyncJSON(stored),
            "parts": .array(storedParts.map { .string(Self.partHash32($0)) }),
            "inline": .bool(storedParts.count == 1 && stored <= SyncSchema.Limits.inlineSatelliteMaxBytes),
        ]
        if !children.isEmpty { object["children"] = .array(children.map(\.value)) }
        if let heldBy { object["heldBy"] = .string(heldBy) }
        json = object
    }

    init?(json value: SyncJSON) {
        guard let object = value.objectValue,
              object["owner"]?.stringValue?.isEmpty == false,
              object["role"]?.stringValue?.isEmpty == false,
              let parts = object["parts"]?.arrayValue, !parts.isEmpty,
              parts.allSatisfy({ $0.stringValue != nil })
        else { return nil }
        json = object
    }

    var owner: String { json["owner"]?.stringValue ?? "" }
    var role: String { json["role"]?.stringValue ?? "" }
    var hash: String { json["hash"]?.stringValue ?? "" }
    var size: Int64? { json["size"]?.int64Value }
    var mime: String? { json["mime"]?.stringValue }
    var encoding: String? { json["enc"]?.stringValue }
    var stored: Int64? { json["stored"]?.int64Value }
    var parts: [String] { json["parts"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    var isInline: Bool { json["inline"]?.boolValue ?? false }
    var heldBy: String? { json["heldBy"]?.stringValue }
    var children: [FileRef] { json["children"]?.arrayValue?.compactMap(FileRef.init(json:)) ?? [] }
    var value: SyncJSON { .object(json) }

    /// Personal satellites (understanding, learner model, draft bases) always stay in private `Content`.
    var isPersonal: Bool { SyncSchema.personalSatelliteRoles.contains(role) }

    /// The satellites' logical ids, this file's parts in order and then each child's, so GC and
    /// prefetch never parse a body.
    var satelliteIDs: [String] {
        parts.map { SyncIdentity.contentID(owner: owner, role: role, partHash32: $0) } + children.flatMap(\.satelliteIDs)
    }

    /// A FileRef as the spec shapes it: owner and role named, a 64-hex `hash`, every part a
    /// 32-hex hash, and an inline body in exactly one part.
    var isWellFormed: Bool {
        Self.isHex(hash, count: 64) && parts.allSatisfy { Self.isHex($0, count: 32) } && (!isInline || parts.count == 1)
            && children.allSatisfy(\.isWellFormed)
    }

    static func partHash32(_ storedPart: Data) -> String {
        String(SHA256.hash(data: storedPart).hexString.prefix(32))
    }

    /// `stored` cut into parts of `partSize` bytes, the last smaller (§3.5.30 rule 7).
    static func split(_ stored: Data, partSize: Int) -> [Data] {
        precondition(partSize > 0, "a part has at least one byte")
        guard !stored.isEmpty else { return [Data()] }
        return stride(from: 0, to: stored.count, by: partSize).map { offset in
            Data(stored[stored.startIndex + offset ..< stored.startIndex + min(offset + partSize, stored.count)])
        }
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
