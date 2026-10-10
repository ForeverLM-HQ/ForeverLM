import Foundation

// MARK: - Realtime rate card, kept for history

/// USD list prices per 1M cached input tokens for the realtime voice and
/// streaming-dictation models ForeverLM ran until 2026-10-01, when every model
/// moved to OpenRouter and realtime voice went with them. Nothing is billed
/// at these rates any more; usage history still reads them to show the cached
/// part of an old charge. Unknown models return nil, never a guess.
enum MobileRealtimeRates {
    private struct CachedInputRates {
        let text: Double
        let audio: Double
    }

    private static func cachedInputRates(for model: String) -> CachedInputRates? {
        switch model {
        case "gpt-realtime-2.1": return CachedInputRates(text: 0.4, audio: 0.4)
        case "gpt-realtime-2.1-mini": return CachedInputRates(text: 0.06, audio: 0.3)
        // Gemini Live had no cache discount; its cached rate was its input rate.
        case "gemini-3.1-flash-live-preview": return CachedInputRates(text: 0.75, audio: 3)
        // The transcribe models published no cached tier either.
        case "gpt-4o-transcribe": return CachedInputRates(text: 2.5, audio: 6)
        case "gpt-4o-mini-transcribe": return CachedInputRates(text: 1.25, audio: 3)
        // Grok Voice billed by the minute and the message, never by token.
        case "grok-voice-think-fast-2.0": return CachedInputRates(text: 0, audio: 0)
        default: return nil
        }
    }

    /// The billed cost that an older server-ledger row's combined cached-token
    /// count could represent. Realtime 2.1 charged cached text and audio at the
    /// same rate, so its bounds collapse to one exact value. Mini did not: old
    /// rows discarded the modality split, and presenting a range is the only
    /// honest reconstruction.
    static func historicCachedBilledCostRange(
        model: String,
        cachedInputTokens: Int
    ) -> ClosedRange<Int>? {
        guard cachedInputTokens > 0, let rates = cachedInputRates(for: model) else { return nil }
        let cachedMillions = Double(cachedInputTokens) / 1_000_000
        let lowerListUSD = cachedMillions * min(rates.text, rates.audio)
        let upperListUSD = cachedMillions * max(rates.text, rates.audio)
        // Historical rows in this date range were charged at provider list
        // cost plus the then-current fixed 15% margin. Keep reconstruction
        // aligned with what those already-recorded D1 debits actually used.
        let lower = Int((lowerListUSD * 1.15 * 1_000_000).rounded())
        let upper = Int((upperListUSD * 1.15 * 1_000_000).rounded())
        return lower...upper
    }
}

/// Spend reads in cents, not dollars: a single chat turn often
/// costs a fraction of a cent, which two-decimal currency would render as
/// "$0.00" — a cost display that says "free" is the one thing this must never
/// do. Precision widens as the number shrinks, so any non-zero cost shows a
/// real figure and only a genuine zero reads as zero.
enum MobileCostFormat {
    static func cents(_ usd: Double) -> String {
        centsValue(usd).map { "\($0)¢" } ?? "0¢"
    }

    /// Said aloud. VoiceOver does not reliably voice "¢", so the unit is spelled.
    static func spokenCents(_ usd: Double) -> String {
        guard let value = centsValue(usd) else { return "zero cents" }
        return "\(value) cents"
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

    /// USD for a live chat. Replies commonly cost less than one cent, so keep
    /// four decimal places there instead of rounding real spend to $0.00.
    static func chatUSD(_ amount: Double) -> String {
        if amount > 0, amount < 0.0001 { return "<$0.0001" }
        return String(format: amount < 0.01 ? "$%.4f" : "$%.2f", amount)
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
