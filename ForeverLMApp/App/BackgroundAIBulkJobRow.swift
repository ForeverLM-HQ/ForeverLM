import SwiftUI

/// A bulk re-queue into a paid background queue, waiting for the learner:
/// how many sources, what the ledger says it will cost, and the three
/// choices. Nothing in the queue spends until one is taken
/// (`BackgroundAISpend.swift`).
struct BackgroundAIBulkJobRow: View {
    @Environment(StudioViewModel.self) private var vm
    let job: BackgroundAIBulkJob
    @State private var isDeciding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "dollarsign.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(job.reason)
            HStack(spacing: 12) {
                Spacer()
                Button("Skip") { decide(.skip) }
                if let affected = job.affectedSourceCount {
                    Button("Only \(affected.formatted()) Affected") { decide(.runAffected) }
                        .help(BackgroundAIBulkJob.costText(job.estimatedAffectedUSD))
                }
                Button("Run All") { decide(.runAll) }
            }
            .buttonStyle(.hoverWash)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .disabled(isDeciding)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background-ai-bulk-job")
    }

    private var message: String {
        let noun = job.heldSourceCount == 1 ? "source" : "sources"
        let cost = BackgroundAIBulkJob.costText(job.estimatedUSD)
        return "\(job.queue.displayName) wants to re-run \(job.heldSourceCount.formatted()) \(noun), \(cost)."
    }

    private func decide(_ decision: BackgroundAIBulkDecision) {
        isDeciding = true
        Task {
            await vm.decideBackgroundAIBulkJob(job, decision)
            isDeciding = false
        }
    }
}
