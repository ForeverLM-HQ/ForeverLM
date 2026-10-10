#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import ForeverLM

/// Where a reading question's marker stands on the PDF page, and how the
/// chip says how a source's questions stand (docs/memory-design.md,
/// "Mnemonic reading on the paper's PDF").
@Suite("Reader questions: markers on the page")
struct ReaderQuestionMarkerGeometryTests {
    static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let size = ReaderQuestionMarkerGeometry.size
    static let inset = ReaderQuestionMarkerGeometry.inset

    @Test("A line that runs across the page puts its marker in the right margin, level with it")
    func fullWidthLine() {
        let line = CGRect(x: 72, y: 400, width: 468, height: 12)
        let marker = ReaderQuestionMarkerGeometry.rect(forLine: line, onPage: Self.page, taken: [])
        #expect(marker.maxX == Self.page.maxX - Self.inset)
        #expect(marker.midY == line.midY)
        #expect(marker.size == CGSize(width: Self.size, height: Self.size))
    }

    @Test("On a two-column page, a line that ends in the left half, a left column's, puts its marker in the left margin")
    func leftColumnLine() {
        let line = CGRect(x: 54, y: 500, width: 230, height: 11)
        let marker = ReaderQuestionMarkerGeometry.rect(forLine: line, onPage: Self.page, twoColumn: true, taken: [])
        #expect(marker.minX == Self.page.minX + Self.inset)
        #expect(ReaderQuestionMarkerGeometry.isOnLeft(marker, page: Self.page))
    }

    @Test("A right column's line puts its marker in the right margin")
    func rightColumnLine() {
        let line = CGRect(x: 320, y: 500, width: 238, height: 11)
        let marker = ReaderQuestionMarkerGeometry.rect(forLine: line, onPage: Self.page, twoColumn: true, taken: [])
        #expect(!ReaderQuestionMarkerGeometry.isOnLeft(marker, page: Self.page))
    }

    @Test("A one-column paragraph's short last line still puts its marker in the right margin")
    func shortLastLineOnOneColumnPage() {
        let line = CGRect(x: 72, y: 300, width: 110, height: 12)
        let marker = ReaderQuestionMarkerGeometry.rect(forLine: line, onPage: Self.page, taken: [])
        #expect(!ReaderQuestionMarkerGeometry.isOnLeft(marker, page: Self.page))
    }

    @Test("A page is two-column when many lines fill each half, not when a few lines end early")
    func detectsColumns() {
        let oneColumn = (0..<40).map { CGRect(x: 72, y: 700 - CGFloat($0) * 14, width: $0 % 9 == 8 ? 90 : 468, height: 12) }
        let twoColumns = (0..<40).map { i in
            CGRect(x: i < 20 ? 54 : 320, y: 700 - CGFloat(i % 20) * 14, width: 234, height: 12)
        }
        #expect(!ReaderQuestionMarkerGeometry.isTwoColumn(lines: oneColumn, page: Self.page))
        #expect(ReaderQuestionMarkerGeometry.isTwoColumn(lines: twoColumns, page: Self.page))
        #expect(!ReaderQuestionMarkerGeometry.isTwoColumn(lines: [], page: Self.page))
    }

    @Test("A marker never leaves the page, at the top or the bottom")
    func clampedToPage() {
        let top = ReaderQuestionMarkerGeometry.rect(
            forLine: CGRect(x: 72, y: 790, width: 400, height: 12), onPage: Self.page, taken: []
        )
        let bottom = ReaderQuestionMarkerGeometry.rect(
            forLine: CGRect(x: 72, y: -4, width: 400, height: 12), onPage: Self.page, taken: []
        )
        #expect(top.maxY <= Self.page.maxY - Self.inset)
        #expect(bottom.minY >= Self.page.minY + Self.inset)
    }

    @Test("Two questions on one line do not share a marker: the second moves down the margin")
    func neighboursDoNotOverlap() {
        let line = CGRect(x: 72, y: 400, width: 468, height: 12)
        let first = ReaderQuestionMarkerGeometry.rect(forLine: line, onPage: Self.page, taken: [])
        let second = ReaderQuestionMarkerGeometry.rect(forLine: line, onPage: Self.page, taken: [first])
        let third = ReaderQuestionMarkerGeometry.rect(forLine: line, onPage: Self.page, taken: [first, second])
        #expect(!first.intersects(second))
        #expect(!first.intersects(third))
        #expect(!second.intersects(third))
        #expect(second.maxY <= first.minY)
    }

    @Test("A page's origin is not assumed to be zero")
    func offsetCropBox() {
        let page = CGRect(x: 18, y: 24, width: 576, height: 744)
        let marker = ReaderQuestionMarkerGeometry.rect(
            forLine: CGRect(x: 90, y: 300, width: 440, height: 12), onPage: page, taken: []
        )
        #expect(marker.maxX == page.maxX - Self.inset)
        #expect(page.contains(marker))
    }

    @Test("The chip names the questions, then how many are answered, then how many are due")
    func chipLine() {
        typealias Counts = MnemonicReadingProgress.Counts
        #expect(ReaderQuestionsChip.line(Counts(questions: 18, answered: 0, due: 0)) == "18 questions")
        #expect(ReaderQuestionsChip.line(Counts(questions: 1, answered: 0, due: 0)) == "1 question")
        #expect(ReaderQuestionsChip.line(Counts(questions: 18, answered: 3, due: 0)) == "3 of 18 answered")
        #expect(ReaderQuestionsChip.line(Counts(questions: 18, answered: 3, due: 2)) == "3 of 18 answered · 2 due")
    }
}
#endif
