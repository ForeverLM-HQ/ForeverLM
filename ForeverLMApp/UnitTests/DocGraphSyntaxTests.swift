import Foundation
import Testing
@testable import ForeverLM

@Suite("Notes graph grammar and daily notes")
struct DocGraphSyntaxTests {

    @Test("A block id is nine lowercase letters and digits, and new ones are valid and distinct")
    func blockIDs() {
        let ids = (0..<200).map { _ in DocGraphSyntax.newBlockID() }
        #expect(ids.allSatisfy(DocGraphSyntax.isBlockID))
        #expect(Set(ids).count == ids.count)
        #expect(!DocGraphSyntax.isBlockID("ABCDEFGHI"))
        #expect(!DocGraphSyntax.isBlockID("abc"))
    }

    @Test("A block id marker ends a block's own text and comes off cleanly")
    func blockIDMarker() {
        #expect(DocGraphSyntax.appendingBlockID("a1b2c3d4e", to: "PINK1 builds up  ") == "PINK1 builds up ^a1b2c3d4e")
        #expect(DocGraphSyntax.blockID(endingLine: "- PINK1 builds up ^a1b2c3d4e") == "a1b2c3d4e")
        #expect(DocGraphSyntax.blockID(endingLine: "x^a1b2c3d4e") == nil, "a caret glued to a word is not a marker")
        #expect(DocGraphSyntax.blockID(endingLine: "PINK1 ^a1b2c3d4e and more") == nil)
        #expect(DocGraphSyntax.removingBlockID(from: "- PINK1 builds up ^a1b2c3d4e") == "- PINK1 builds up")
    }

    @Test("References, embeds, title links and tags match the stored forms, escaped ones included")
    func patterns() throws {
        func matches(_ pattern: String, _ text: String) throws -> [String] {
            let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
                (1..<match.numberOfRanges)
                    .map { match.range(at: $0) }
                    .first { $0.location != NSNotFound }
                    .map(ns.substring(with:)) ?? ""
            }
        }
        #expect(try matches(DocGraphSyntax.blockReferencePattern, "As ((a1b2c3d4e)) says, and ((zz9zz9zz9)).") == ["a1b2c3d4e", "zz9zz9zz9"])
        #expect(try matches(DocGraphSyntax.blockEmbedPattern, "{{embed: ((a1b2c3d4e))}}") == ["a1b2c3d4e"])
        #expect(try matches(DocGraphSyntax.blockEmbedPattern, "{{[[embed]]: ((a1b2c3d4e))}}") == ["a1b2c3d4e"])
        #expect(try matches(DocGraphSyntax.titleLinkPattern, "See [[Mitophagy]] and \\[\\[Membrane potential\\]\\].") == ["Mitophagy", "Membrane potential"])
        #expect(try matches(DocGraphSyntax.tagPattern, "#reading about #[[Membrane potential]] (#todo) in C#.") == ["reading", "Membrane potential", "todo"])
        #expect(try matches(DocGraphSyntax.tagPattern, "\\#reading at the start of a line") == ["reading"])
        #expect(try matches(DocGraphSyntax.tagPattern, "## A heading and #1 and # alone") == ["1"])
    }

    @Test("Titles compare without case, accents or extra spaces, and a stored escape is undone")
    func titles() {
        #expect(DocGraphSyntax.normalizedTitle("  Mitochondrial   Membrane Potential ") == DocGraphSyntax.normalizedTitle("mitochondrial membrane potential"))
        #expect(DocGraphSyntax.normalizedTitle("Crème") == DocGraphSyntax.normalizedTitle("creme"))
        #expect(DocGraphSyntax.unescapedTitle("A \\[draft\\]") == "A [draft]")
    }

    @Test("A daily note's id is its day, its title is the day written out, and both read back")
    func dailyNotes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 0, minute: 35)))
        #expect(DailyNote.dayKey(for: date, calendar: calendar) == "2026-10-06")
        #expect(DailyNote.id(for: date, calendar: calendar) == "daily-2026-10-06")
        #expect(DailyNote.isDailyNoteID("daily-2026-10-06"))
        #expect(!DailyNote.isDailyNoteID("daily-2026-02-30"))
        #expect(!DailyNote.isDailyNoteID("notes:abc"))
        #expect(DailyNote.title(for: date, calendar: calendar) == "October 6th, 2026")
        #expect(DailyNote.title(forDayKey: "2026-10-01", calendar: calendar) == "October 1st, 2026")
        #expect(DailyNote.title(forDayKey: "2026-10-22", calendar: calendar) == "October 22nd, 2026")
        #expect(DailyNote.title(forDayKey: "2026-10-13", calendar: calendar) == "October 13th, 2026")
        #expect(DailyNote.dayKey(fromTitle: "October 6th, 2026", calendar: calendar) == "2026-10-06")
        #expect(DailyNote.dayKey(fromTitle: "Oct 6, 2026", calendar: calendar) == "2026-10-06")
        #expect(DailyNote.dayKey(fromTitle: "Mitophagy", calendar: calendar) == nil)
    }

    @Test("A Doc can link an Idea, and the address reads back")
    func ideaLinks() throws {
        let link = StudioEntityLink.idea("C0FFEE")
        #expect(link.markdownDestination == "foreverlm://idea/C0FFEE")
        #expect(StudioEntityLink.parse(destination: "foreverlm://idea/C0FFEE") == link)
        #expect(link.markdown(title: "Depolarised cells") == "[Depolarised cells](foreverlm://idea/C0FFEE)")
    }
}
