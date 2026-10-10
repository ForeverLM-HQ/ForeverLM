import Foundation
import Testing
@testable import ForeverLM

/// The shared value shapes (§3.3): each keeps the JSON it came from, so keys a newer client writes
/// survive, and a FileRef names every satellite from its owner, role and part hashes.
@Suite("Sync values coding")
struct SyncValuesCodingTests {
    @Test("The locator vectors hold")
    func vectors() {
        SyncVectorRunner.expectCases("locator")
    }

    @Test("A FileRef names its parts' satellites by owner and role, children after, in order")
    func fileRefNames() throws {
        let stored = Data((0..<1_000).map { UInt8($0 % 251) })
        let parts = FileRef.split(stored, partSize: 400)
        #expect(parts.map(\.count) == [400, 400, 200])
        let child = FileRef(owner: "src_1", role: "walkthroughPicture", hash: SyncIdentity.sha256Hex(Data("p".utf8)), size: 1,
                            mime: "image/png", encoding: "identity", storedParts: [Data("p".utf8)])
        let file = FileRef(owner: "src_1", role: "pdf", hash: SyncIdentity.sha256Hex(stored), size: Int64(stored.count),
                           mime: "application/pdf", encoding: "identity", storedParts: parts, children: [child])
        #expect(file.parts == parts.map(FileRef.partHash32))
        #expect(file.parts.allSatisfy { $0.count == 32 })
        #expect(!file.isInline)
        #expect(file.stored == 1_000)
        #expect(file.satelliteIDs == parts.map { "ct:src_1:pdf:\(FileRef.partHash32($0))" } + ["ct:src_1:walkthroughPicture:\(FileRef.partHash32(Data("p".utf8)))"])
        #expect(file.isWellFormed)
        // A copy into another record keeps the FileRef verbatim, owner and all (D41).
        let copied = try #require(FileRef(json: file.value))
        #expect(copied == file && copied.owner == "src_1")
    }

    @Test("A FileRef keeps keys it does not know and refuses one without an owner, a role or parts")
    func fileRefShape() throws {
        let raw: SyncJSON = ["owner": "root", "role": "moveMap.mj-1.1", "hash": .string(String(repeating: "a", count: 64)), "size": 3,
                             "mime": "application/json", "enc": "gzip", "stored": 20, "parts": [.string(String(repeating: "b", count: 32))],
                             "inline": true, "future": ["kept": true]]
        let file = try #require(FileRef(json: raw))
        #expect(file.value == raw)
        #expect(file.isWellFormed)
        #expect(!file.isPersonal)
        #expect(FileRef(json: ["role": "pdf", "parts": ["x"]]) == nil)
        #expect(FileRef(json: ["owner": "a", "role": "pdf", "parts": []]) == nil)
        var personal = raw.objectValue!
        personal["role"] = "understanding"
        #expect(FileRef(json: .object(personal))?.isPersonal == true)
        var badHash = raw.objectValue!
        badHash["hash"] = "ABC"
        #expect(FileRef(json: .object(badHash))?.isWellFormed == false)
    }

    @Test("ItemRefs split a sub-key at the first #, except card and work-key ids, which carry # themselves")
    func itemRefs() throws {
        let idea = try #require(ItemRef("src:src_2cd9#idea-17"))
        #expect(idea.kind == .source && idea.id == "src_2cd9" && idea.subKey == "idea-17")
        let question = try #require(ItemRef("qz:cq-1913#q3"))
        #expect(question.kind == .quiz && question.subKey == "q3")
        let card = try #require(ItemRef("crd:card:src_2cd9:walk:src_2cd9#q3"))
        #expect(card.kind == .card && card.id == "card:src_2cd9:walk:src_2cd9#q3" && card.subKey == nil)
        let podcast = try #require(ItemRef("wk:podcast:example.com/rss#guid-7"))
        #expect(podcast.kind == .workKey && podcast.id == "podcast:example.com/rss#guid-7")
        #expect(ItemRef("all")?.kind == .all)
        #expect(ItemRef("future:x#y")?.kind == .unknown("future"))
        #expect(ItemRef("future:x#y")?.id == "x#y")
        #expect(ItemRef("no colon") == nil)
        #expect(ItemRef("src:") == nil)
        for text in ["src:src_2cd9#idea-17", "qz:cq-1913#q3", "crd:card:a#b", "all", "exc:e1"] {
            #expect(ItemRef(text)?.rawValue == text)
        }
    }

    @Test("Locator, Span, ReaderContext, Person and MadeBy round-trip their JSON, unknown keys included")
    func shapesRoundTrip() throws {
        let locator = Locator(.text, ["offset": 10, "len": 5, "quote": "cells"])
        #expect(locator.kind == .text && locator["quote"] == "cells")
        #expect(Locator(json: locator.value) == locator)
        let span = LocatorSpan(from: Locator(.pdf, ["page": 12]), to: Locator(.pdf, ["page": 40]))
        #expect(span.isValid && span.from["page"] == 12)
        let context = ReaderContext(notebookID: "nb1", chatID: "cht1")
        #expect(context.value == ["notebookID": "nb1", "chatID": "cht1"])
        #expect(ReaderContext(json: ["spaceID": "s1", "future": 1])?.spaceID == "s1")
        let person = SyncPerson(user: "_abc", name: "Robin")
        #expect(SyncPerson(json: person.value) == person && person.name == "Robin")
        #expect(SyncPerson(json: ["name": "No user"]) == nil)
        let madeBy = MadeBy(route: "ios", device: "k3f7ab2q", at: 1_759_400_000_000, chatID: "cht1")
        #expect(MadeBy(json: madeBy.value) == madeBy && madeBy.at == 1_759_400_000_000)
    }

    @Test("JSON values keep booleans apart from 0 and 1, and integers below 2^53 exact")
    func jsonValues() throws {
        let parsed = try SyncJSON(parsing: Data(#"{"zero":0,"one":1,"no":false,"yes":true,"ms":1759400000123,"f":0.42,"s":"é"}"#.utf8))
        #expect(parsed["zero"] == .number(0) && parsed["one"] == .number(1))
        #expect(parsed["no"] == .bool(false) && parsed["yes"] == .bool(true))
        #expect(parsed["ms"]?.int64Value == 1_759_400_000_123)
        #expect(try SyncJSON(parsing: parsed.serialized()) == parsed)
        #expect(String(decoding: SyncJSON.number(1_759_400_000_123).serialized(), as: UTF8.self) == "1759400000123")
        #expect(String(decoding: (["b": 1, "a": "\u{1}\"\\"] as SyncJSON).serialized(), as: UTF8.self) == #"{"a":"\u0001\"\\","b":1}"#)
    }
}
