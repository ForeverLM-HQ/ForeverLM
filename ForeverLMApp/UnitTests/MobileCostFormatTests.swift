import Testing
@testable import ForeverLM

// How spend reads on the phone (`MobileCostFormat`), and the one piece of the
// realtime rate card usage history still needs: the cached part of an old
// realtime charge, reconstructed from its model and token count. Realtime
// voice went on 2026-10-01; its rows stay in the ledger and must still read
// right.
struct MobileCostFormatTests {
    /// A chat turn often costs a fraction of a cent. Dollars with two
    /// decimals would render that as "$0.00" — reading as free, which is the
    /// one thing a cost display must never do. Cents keep a real figure.
    @Test("Sub-cent spend shows a real figure in cents")
    func subCentCostShowsRealFigure() {
        // $0.004 is four tenths of a cent.
        #expect(MobileCostFormat.cents(0.004) == "0.40¢")
    }

    @Test("Precision widens as the amount shrinks")
    func precisionWidensForSmallAmounts() {
        #expect(MobileCostFormat.cents(0.42) == "42¢")       // 42 cents
        #expect(MobileCostFormat.cents(0.042) == "4.2¢")     // 4.2 cents
        #expect(MobileCostFormat.cents(0.0042) == "0.42¢")   // 0.42 cents
    }

    /// Below a hundredth of a cent even two decimals print 0.00, so that case
    /// states a bound instead of claiming zero.
    @Test("Vanishingly small spend states a bound, never zero")
    func vanishinglySmallSpendIsBounded() {
        #expect(MobileCostFormat.cents(0.00000001) == "<0.01¢")
    }

    @Test("Only genuine zero renders as zero")
    func zeroCostRendersAsZero() {
        #expect(MobileCostFormat.cents(0) == "0¢")
    }

    /// The account balance stays in dollars — a standing amount in the tens of
    /// dollars would read as "362¢".
    @Test("Balance renders as dollars")
    func balanceRendersAsDollars() {
        #expect(MobileCostFormat.usd(3.6231).contains("3.62"))
    }

    @Test("Cache hit rate renders as a whole percentage")
    func hitRateRendersAsPercent() {
        #expect(MobileCostFormat.percent(0.75).contains("75"))
    }
}
