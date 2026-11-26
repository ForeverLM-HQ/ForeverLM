import Foundation
import Testing
@testable import ForeverLM

/// The same article at two addresses is one work; another article's text
/// under a title of its own is a wrong page.
@Suite("Duplicate article text")
struct DuplicateArticleTextTests {
    private static func body(_ seed: String, words: Int = 400) -> String {
        (0..<words).map { "\(seed)\($0 % 97)w\($0)" }.joined(separator: " ")
    }

    private let partTwo = "# Stories We'd Like to Publish (Part II)\n" + Self.body("asimov")

    @Test("One article at two addresses, its title with and without the publication")
    func sameWorkAcrossDomains() {
        let a = DuplicateArticleText.Copy(id: "a", title: "Stories We'd Like to Publish (Part II) - Asimov Press", text: partTwo)
        let b = DuplicateArticleText.Copy(id: "b", title: "Stories We'd Like to Publish", text: "Stories We'd Like to Publish\n" + partTwo)
        #expect(DuplicateArticleText.verdict(a, b) == .sameWork)
    }

    @Test("A source holding another article's page is the one whose text opens with the other's title")
    func wrongPageIsNamed() {
        let text = "# CAR-T combinatorics\n" + Self.body("cart")
        let right = DuplicateArticleText.Copy(id: "right", title: "CAR-T combinatorics - by Elliot Hershberg", text: "CAR-T combinatorics - by Elliot Hershberg\n\n" + text)
        let wrong = DuplicateArticleText.Copy(id: "wrong", title: "The genetics of immunity - by Elliot Hershberg", text: "The genetics of immunity - by Elliot Hershberg\n\n" + text)
        #expect(DuplicateArticleText.verdict(right, wrong) == .holdsOthersText("wrong"))
        #expect(DuplicateArticleText.verdict(wrong, right) == .holdsOthersText("wrong"))
    }

    @Test("Without a heading, the first line after the stored title says whose text it is")
    func unheadedTextUsesItsOpeningLine() {
        let text = Self.body("popmech")
        let pop = DuplicateArticleText.Copy(id: "pop", title: "Your Body Can Beat Death, Says One Harvard Scientist", text: "Your Body Can Beat Death, Says One Harvard Scientist\nYour Body Can Beat Death, Harvard Scientist Says\n" + text)
        let fda = DuplicateArticleText.Copy(id: "fda", title: "What America Needs from a New FDA Commissioner", text: "What America Needs from a New FDA Commissioner\nYour Body Can Beat Death, Harvard Scientist Says\n" + text)
        #expect(DuplicateArticleText.verdict(pop, fda) == .holdsOthersText("fda"))
    }

    @Test("Different texts, short texts and very different lengths are never the same")
    func differentTextsStayApart() {
        let a = DuplicateArticleText.Copy(id: "a", title: "One", text: Self.body("one"))
        let b = DuplicateArticleText.Copy(id: "b", title: "One", text: Self.body("two"))
        #expect(DuplicateArticleText.verdict(a, b) == .different)
        let short = DuplicateArticleText.Copy(id: "s", title: "One", text: Self.body("one", words: 120))
        #expect(DuplicateArticleText.verdict(short, short) == .different)
        let long = DuplicateArticleText.Copy(id: "l", title: "One", text: Self.body("one") + " " + Self.body("more", words: 300))
        #expect(DuplicateArticleText.verdict(a, long) == .different)
    }

    @Test("Titles agree across a byline, a publication and a notification count")
    func titleAgreement() {
        #expect(DuplicateArticleText.titlesAgree("(1) An indication selection resource for longevity", "An indication selection resource for longevity"))
        #expect(DuplicateArticleText.titlesAgree("Energy Constraint on Health", "Energy Constraint Impacts on Health - by Martin Picard"))
        #expect(DuplicateArticleText.titlesAgree("GLP-1 Drugs for Aging? | Science | AAAS", "GLP-1 Drugs for Aging?"))
        #expect(!DuplicateArticleText.titlesAgree("CAR-T combinatorics - by Elliot Hershberg", "The genetics of immunity - by Elliot Hershberg"))
    }

    @Test("The library pass pairs only copies holding the same text")
    func libraryPassPairs() {
        let copies = [
            DuplicateArticleText.Copy(id: "a", title: "Stories We'd Like to Publish (Part II)", text: partTwo),
            DuplicateArticleText.Copy(id: "b", title: "Stories We'd Like to Publish", text: partTwo),
            DuplicateArticleText.Copy(id: "c", title: "Something else", text: Self.body("else")),
        ]
        let pairs = StudioViewModel.sameTextPairs(copies)
        #expect(pairs.count == 1)
        #expect(pairs.first?.verdict == DuplicateArticleText.Verdict.sameWork)
    }
}
