import CoreGraphics
import Testing
@testable import ForeverLM

@Suite("Tour after Setup")
struct AppTourTests {

    @Test("The tour opens on the map, which waits for Next")
    func mapStep() {
        let busy = AppTourSignals(readerSourceID: "x", paneCount: 4, memoryShown: true, spaceShown: true)
        #expect(AppTourStep.allCases.first == .map)
        #expect(!AppTourStep.map.isAction)
        #expect(!AppTourStep.map.isDone(now: busy, entry: AppTourSignals()))
    }

    @Test("Opening a source counts only for a source that was not already open")
    func openSourceStep() {
        let entry = AppTourSignals(readerSourceID: "source-a")
        #expect(!AppTourStep.openSource.isDone(now: entry, entry: entry))
        #expect(AppTourStep.openSource.isDone(now: AppTourSignals(readerSourceID: "source-b"), entry: entry))
        #expect(!AppTourStep.openSource.isDone(now: AppTourSignals(readerSourceID: nil), entry: entry))
    }

    @Test("Dragging a chat beside counts once a pane is added")
    func splitStep() {
        let entry = AppTourSignals(paneCount: 2)
        #expect(!AppTourStep.splitChat.isDone(now: AppTourSignals(paneCount: 2), entry: entry))
        #expect(AppTourStep.splitChat.isDone(now: AppTourSignals(paneCount: 3), entry: entry))
    }

    @Test("Memory and the Space are done once they show")
    func placeSteps() {
        let entry = AppTourSignals()
        #expect(!AppTourStep.memory.isDone(now: entry, entry: entry))
        #expect(AppTourStep.memory.isDone(now: AppTourSignals(memoryShown: true), entry: entry))
        #expect(!AppTourStep.space.isDone(now: entry, entry: entry))
        #expect(AppTourStep.space.isDone(now: AppTourSignals(spaceShown: true), entry: entry))
    }

    @Test("The sidebar step wants it folded and brought back")
    func sidebarStep() {
        let entry = AppTourSignals()
        #expect(!AppTourStep.sidebar.isDone(now: entry, entry: entry, sidebarFlips: 1))
        #expect(AppTourStep.sidebar.isDone(now: entry, entry: entry, sidebarFlips: 2))
    }

    @Test("Read-only steps wait for Next, and the last step has none after it")
    func readSteps() {
        let busy = AppTourSignals(readerSourceID: "x", paneCount: 4, memoryShown: true, spaceShown: true)
        for step in [AppTourStep.map, .ask, .corner] {
            #expect(!step.isAction)
            #expect(!step.isDone(now: busy, entry: AppTourSignals(), sidebarFlips: 3))
        }
        #expect(AppTourStep.corner.next == nil)
        #expect(AppTourStep.map.next == .openSource)
    }

    @Test("Every step says it in a few words")
    func fewWords() {
        for step in AppTourStep.allCases {
            #expect(step.title.split(separator: " ").count <= 3, "\(step)")
            #expect(step.line.split(separator: " ").count <= 9, "\(step)")
        }
    }

    @Test("The card stands beside a strip icon, inside a pane, and in the window")
    func placement() {
        let window = CGSize(width: 1200, height: 800)
        let icon = CGRect(x: 8, y: 200, width: 36, height: 30)
        let beside = AppTourLayout.cardCenter(spot: icon, in: window)
        #expect(beside.x - AppTourLayout.cardWidth / 2 > icon.maxX)
        #expect(abs(beside.y - icon.midY) < 1)

        let pane = CGRect(x: 300, y: 0, width: 800, height: 800)
        let inPane = AppTourLayout.cardCenter(spot: pane, in: window)
        #expect(pane.contains(inPane))
        #expect(inPane.y > pane.midY)

        let centre = AppTourLayout.cardCenter(spot: nil, in: window)
        #expect(centre == CGPoint(x: 600, y: 400))

        // A spot low on the left edge keeps the card on screen.
        let low = AppTourLayout.cardCenter(spot: CGRect(x: 8, y: 780, width: 36, height: 30), in: window)
        #expect(low.y + AppTourLayout.cardHeight / 2 <= window.height - AppTourLayout.margin)
    }
}
