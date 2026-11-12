import Foundation

/// Spend reads in cents, not dollars: a single chat turn often
/// costs a fraction of a cent, which two-decimal currency would render as
/// "$0.00" — a cost display that says "free" is the one thing this must never
/// do. Precision widens as the number shrinks, so any non-zero cost shows a
/// real figure and only a genuine zero reads as zero.
enum MobileCostFormat {
    static func cents(_ usd: Double) -> String {
        centsValue(usd).map { "\($0)¢" } ?? "0¢"
    }

    private static func centsValue(_ usd: Double) -> String? {
        let cents = usd * 100
        guard cents > 0 else { return nil }
        // Below a hundredth of a cent even two decimals would print 0.00, so
        // that one case stays a bound rather than a lie.
        if cents < 0.01 { return "<0.01" }
        if cents < 1 { return cents.formatted(.number.precision(.fractionLength(2))) }
        if cents < 10 { return cents.formatted(.number.precision(.fractionLength(1))) }
        return cents.formatted(.number.precision(.fractionLength(0)))
    }

    /// Dollars, for the account balance — that one is a standing amount in the
    /// tens of dollars, where cents would read as "362¢".
    static func usd(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// Ledger amounts span four orders of magnitude — a single reply is a
    /// fraction of a cent, a month of talking is dollars — so the unit
    /// follows the size: dollars from $1 up, cents below.
    static func money(microUSD: Int) -> String {
        let usd = Double(microUSD) / 1_000_000
        return usd >= 1 ? Self.usd(usd) : cents(usd)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
