// The composer's context gauge, its popover and the token and cost text helpers.

import SwiftUI

/// Claude-style context gauge: a small ring in the composer showing how full
/// the model's context window is, with a popover breaking the estimate down by
/// component and per attached source, plus the latest request's prompt-cache
/// read/write counts from the local usage ledger.
struct ChatContextGauge: View {
    let breakdown: ReviewSessionManager.ChatContextBreakdown
    let sessionCost: ReviewSessionManager.ChatSessionCost?
    /// The chat ⋯'s Context and Cost…: true opens the breakdown, and the
    /// gauge sets it back to false once the breakdown closes.
    @Binding var isBreakdownRequested: Bool
    @State private var isPopoverPresented = false

    init(
        breakdown: ReviewSessionManager.ChatContextBreakdown,
        sessionCost: ReviewSessionManager.ChatSessionCost?,
        isBreakdownRequested: Binding<Bool> = .constant(false)
    ) {
        self.breakdown = breakdown
        self.sessionCost = sessionCost
        self._isBreakdownRequested = isBreakdownRequested
    }

    var body: some View {
        Button {
            isPopoverPresented = true
        } label: {
            ZStack {
                // Dashed track when no host has published a window: the ring
                // then has nothing to fill against.
                Circle()
                    .stroke(
                        Color.primary.opacity(0.15),
                        style: StrokeStyle(lineWidth: 2.5, dash: breakdown.contextWindowTokens == nil ? [2, 2] : [])
                    )
                Circle()
                    .trim(from: 0, to: max(0.03, breakdown.usedFraction))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            .padding(4)
            .contentShape(Circle())
        }
        .buttonStyle(.hoverWash(in: Circle(), opacity: 0.12))
        .help("Context window: \(breakdown.headlineText) — click for the breakdown")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            ChatContextGaugePopover(breakdown: breakdown, sessionCost: sessionCost)
        }
        // Asked for from the ⋯: open as the ring appears, and give the ask
        // back when the breakdown closes, so the ring goes with it unless the
        // context is filling up.
        .task(id: isBreakdownRequested) {
            if isBreakdownRequested { isPopoverPresented = true }
        }
        .onChange(of: isPopoverPresented) { _, presented in
            if !presented, isBreakdownRequested { isBreakdownRequested = false }
        }
        // A ring that goes with its breakdown still open — another chat
        // opened, the mic took the row — gives the ask back too, or the next
        // ring would open its breakdown unasked.
        .onDisappear {
            if isBreakdownRequested { isBreakdownRequested = false }
        }
    }

    private var ringColor: Color {
        switch breakdown.usedFraction {
        case ..<0.7: return .accentColor
        case ..<0.9: return .orange
        default: return .red
        }
    }
}

private struct ChatContextGaugePopover: View {
    let breakdown: ReviewSessionManager.ChatContextBreakdown
    let sessionCost: ReviewSessionManager.ChatSessionCost?

    private struct ComponentRow: Identifiable {
        let id: String
        let label: String
        let tokens: Int
        let color: Color
    }

    private var componentRows: [ComponentRow] {
        var rows: [ComponentRow] = [
            ComponentRow(id: "instructions", label: "Instructions", tokens: breakdown.instructionTokens, color: Color.accentColor)
        ]
        if breakdown.sourceTokens > 0 {
            rows.append(ComponentRow(id: "sources", label: "Attached sources", tokens: breakdown.sourceTokens, color: Color.accentColor.opacity(0.75)))
        }
        if breakdown.toolTokens > 0 {
            rows.append(ComponentRow(id: "tools", label: "App tools", tokens: breakdown.toolTokens, color: Color.accentColor.opacity(0.55)))
        }
        rows.append(ComponentRow(id: "conversation", label: "Conversation & tool results", tokens: breakdown.conversationTokens, color: Color.accentColor.opacity(0.4)))
        if breakdown.volatileTokens > 0 {
            rows.append(ComponentRow(id: "volatile", label: "History digest & turn notes", tokens: breakdown.volatileTokens, color: Color.accentColor.opacity(0.25)))
        }
        if let freeTokens = breakdown.freeTokens {
            rows.append(ComponentRow(id: "free", label: "Free space", tokens: freeTokens, color: Color.primary.opacity(0.10)))
        }
        return rows
    }

    /// Sources shown individually before collapsing into "+N more".
    private let maxSourceRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Context window")
                    .font(.headline)
                Spacer()
                Text(breakdown.headlineText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plainTextSummary, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.hoverWash)
                .foregroundStyle(.secondary)
                .help("Copy this breakdown")
            }

            Text("\(breakdown.providerName) · \(breakdown.modelID)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            usageBar

            VStack(alignment: .leading, spacing: 5) {
                ForEach(componentRows) { row in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(row.color)
                            .frame(width: 8, height: 8)
                        Text(row.label)
                            .font(.caption)
                        Spacer()
                        Text(chatTokenText(row.tokens))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(percentText(row.tokens))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            if !breakdown.perSource.isEmpty {
                Divider()
                sourceRows
            }

            Divider()
            cacheSection

            if sessionCost != nil {
                Divider()
                costSection
            }

            if breakdown.contextWindowTokens == nil {
                Text(unknownWindowNote)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
        .textSelection(.enabled)
    }

    /// Everything the popover shows, flattened for the clipboard so a breakdown
    /// can be pasted into a bug report without retyping the numbers.
    private var plainTextSummary: String {
        var lines: [String] = [
            "Context window: \(breakdown.headlineText)",
            "\(breakdown.providerName) · \(breakdown.modelID)",
            ""
        ]
        for row in componentRows {
            lines.append("\(row.label): \(chatTokenText(row.tokens)) (\(percentText(row.tokens)))")
        }

        if !breakdown.perSource.isEmpty {
            lines.append("")
            lines.append("Per source")
            for share in breakdown.perSource {
                lines.append("\(share.title): \(chatTokenText(breakdown.tokens(share.characters)))")
            }
            let attributed = breakdown.perSource.reduce(0) { $0 + $1.characters }
            let remainder = breakdown.tokens(breakdown.sourceCharacters - attributed)
            if remainder > 0 {
                lines.append("Source inventory & retrieved excerpts: \(chatTokenText(remainder))")
            }
        }

        lines.append("")
        lines.append("Prompt cache — last request")
        if let cache = lastRequestCache {
            lines.append("Read from cache: \(chatTokenText(cache.reads))")
            lines.append("Written to cache: \(chatTokenText(cache.writes))")
            lines.append("Fresh input: \(chatTokenText(cache.fresh))")
        } else {
            lines.append("No completed request on \(breakdown.providerName) yet in this app run.")
        }

        if let cost = sessionCost {
            lines.append("")
            lines.append("Cost — this chat")
            lines.append("\(cost.eventCount) request\(cost.eventCount == 1 ? "" : "s"): \(chatCostText(cost.totalUSD))")
            if cost.unpricedEventCount > 0 {
                lines.append("\(cost.unpricedEventCount) of these carried no price — the total is a floor.")
            }
        }

        lines.append("")
        if breakdown.contextWindowTokens == nil { lines.append(unknownWindowNote) }
        lines.append(footnote)
        return lines.joined(separator: "\n")
    }

    private var usageBar: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(componentRows) { row in
                    row.color
                        .frame(width: max(0, proxy.size.width * fraction(row.tokens)))
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var sourceRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Per source")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(breakdown.perSource.prefix(maxSourceRows)) { share in
                HStack(spacing: 6) {
                    Text(share.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(chatTokenText(breakdown.tokens(share.characters)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if breakdown.perSource.count > maxSourceRows {
                Text("+ \(breakdown.perSource.count - maxSourceRows) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            // Attributed against characters, not the rounded per-row tokens, so
            // the remainder can't pick up rounding drift across many sources.
            let attributed = breakdown.perSource.reduce(0) { $0 + $1.characters }
            let remainder = breakdown.tokens(breakdown.sourceCharacters - attributed)
            if remainder > 0 {
                HStack(spacing: 6) {
                    Text("Source inventory & retrieved excerpts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(chatTokenText(remainder))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// Cache read/write/fresh split for the last streamed chat request on this
    /// provider, as the provider itself reported it. Nil until one completes.
    private var lastRequestCache: (reads: Int, writes: Int, fresh: Int)? {
        guard let event = ChatUsageLiveMonitor.shared.latestStreamChatEvent,
              event.provider == breakdown.providerName else { return nil }
        let reads = event.cachedInputTokens ?? 0
        let writes = event.cacheCreationInputTokens ?? 0
        let input = event.inputTokens ?? 0
        // Anthropic's input_tokens already excludes cache reads and writes;
        // OpenAI-style providers fold cached reads into prompt_tokens.
        let fresh = breakdown.providerName == AIProvider.anthropic.shortName
            ? input
            : max(0, input - reads)
        return (reads, writes, fresh)
    }

    /// True when the last request re-read most of the stable prefix
    /// (instructions + sources + tools) from cache rather than paying full price.
    private var stablePrefixWasCached: Bool {
        guard let cache = lastRequestCache else { return false }
        let stablePrefixTokens = breakdown.instructionTokens + breakdown.sourceTokens + breakdown.toolTokens
        guard stablePrefixTokens > 0 else { return false }
        return Double(cache.reads) >= 0.7 * Double(stablePrefixTokens)
    }

    @ViewBuilder
    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt cache — last request")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if let cache = lastRequestCache {
                cacheRow("Read from cache", cache.reads)
                cacheRow("Written to cache", cache.writes)
                cacheRow("Fresh input", cache.fresh)

                if stablePrefixWasCached {
                    Label("Instructions, sources, and tools were served from cache", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            } else {
                Text("No completed request on \(breakdown.providerName) yet in this app run.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func cacheRow(_ label: String, _ tokens: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
            Spacer()
            Text(chatTokenText(tokens))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var costSection: some View {
        if let cost = sessionCost {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cost — this chat")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(cost.eventCount == 1 ? "1 request" : "\(cost.eventCount) requests")
                        .font(.caption)
                    Spacer()
                    Text(chatCostText(cost.totalUSD))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if cost.unpricedEventCount > 0 {
                    Text("\(cost.unpricedEventCount) of these carried no price — the total is a floor.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Says exactly how much of the panel is measured. The total is the
    /// provider's own number once a request has completed; the split across
    /// components stays a proportional attribution either way, because
    /// providers bill a request as a whole, never per component.
    private var footnote: String {
        guard breakdown.isCalibrated else {
            return "Estimated at ~\(AIService.approxCharsPerToken) characters per token until the first request completes."
        }
        let ratio = String(format: "%.1f", breakdown.charactersPerToken)
        let source = breakdown.measuredPromptTokens == nil ? "the last request" : "this request"
        return "Total measured from \(source) (\(ratio) characters per token); the split across components is proportional."
    }

    /// No host published a window for this model, so the popover shows the
    /// request's composition without percentages and says why.
    private var unknownWindowNote: String {
        "No context window is published for \(breakdown.modelID) on \(breakdown.providerName), so no percentage is shown and nothing is trimmed to fit."
    }

    /// Share of the window — or, when none is published, share of the request
    /// itself, so the bar still shows how the request is composed.
    private func fraction(_ tokens: Int) -> Double {
        let denominator = breakdown.contextWindowTokens ?? breakdown.usedTokens
        guard denominator > 0 else { return 0 }
        return Double(tokens) / Double(denominator)
    }

    private func percentText(_ tokens: Int) -> String {
        guard let window = breakdown.contextWindowTokens, window > 0 else { return "—" }
        let percent = 100 * Double(tokens) / Double(window)
        if percent > 0 && percent < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", percent)
    }
}

extension ReviewSessionManager.ChatContextBreakdown {
    var usedPercentText: String {
        String(format: "%.0f%%", 100 * usedFraction)
    }

    /// "115k / 256k (45%)", or "115k · window not published" when no host has
    /// published one — never a percentage of a guessed denominator.
    var headlineText: String {
        let used = approximationPrefix + chatTokenText(usedTokens)
        guard let window = contextWindowTokens else { return "\(used) · window not published" }
        return "\(used) / \(chatTokenText(window)) (\(usedPercentText))"
    }

    /// "~" only while the numbers are still the raw character guess.
    var approximationPrefix: String { isCalibrated ? "" : "~" }
}

func chatTokenText(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 10_000 { return String(format: "%.0fk", Double(value) / 1_000) }
    if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
    return "\(value)"
}

/// USD amount for the chat cost rows. Same convention as the AI Usage pane:
/// sub-cent amounts keep four decimals so a cheap cached turn doesn't round
/// to a flat $0.00 the moment it costs anything.
func chatCostText(_ usd: Double) -> String {
    if usd > 0 && usd < 0.01 { return String(format: "$%.4f", usd) }
    return String(format: "$%.2f", usd)
}
