#if os(macOS)
import Foundation

// MARK: - A notebook's reports, from the Studio column
//
// The Studio column's Report tile (docs/notebooks-design.md, "Reports")
// opens its options first — the format, the document for feedback, a focus
// or a custom instruction, which sources, the price — and makes on the
// second tap (Gemini's two-click lesson). The tile asks only this:
// `presentReportOptions(notebookID:format:)`; the sheet, the run, its pending
// row and where the made Doc opens are the report's own
// (ReportOptionsSheet.swift, ReportGenerationCoordinator.swift).

/// The Studio's Report: whether it is offered, and its formats. The Studio
/// column's tile and the Notebook menu's Make ▸ Report draw a Report only
/// while it is available, one item per format, each calling
/// `presentReportOptions(notebookID:format:)`.
enum ReportEntry {
    /// The report generator is here: the tile and the menu item are shown.
    static var isAvailable: Bool { true }

    /// What a report can be, in Gemini Notebook's order, each with its menu
    /// word (`title`) and glyph (`symbolName`).
    typealias Format = ReportFormat
}

extension StudioViewModel {

    /// The Report tile's first tap, or one of its menu's formats: the options
    /// sheet for the notebook, in the window it was asked from, opening on
    /// `format` (nil opens on the default, Briefing). A notebook that cannot
    /// take a report — archived, or a team's this account can only read —
    /// says why in a toast instead, and nothing opens.
    func presentReportOptions(notebookID: String, format: ReportFormat?) {
        guard let target = reportOptionsTarget(notebookID: notebookID, format: format) else { return }
        ReportGenerationCoordinator.shared.present(target)
    }

    /// The options sheet's target in the active window, or nil (with a toast
    /// saying why) for a notebook that cannot take a report. `sourceIDs`
    /// names the sources to write from; nil reads the ticked ones.
    func reportOptionsTarget(
        notebookID: String,
        format: ReportFormat?,
        sourceIDs: [String]? = nil
    ) -> ReportOptionsTarget? {
        if let refusal = reportRefusal(notebookID: notebookID) {
            let title = notebook(id: notebookID)?.title ?? "this notebook"
            showToast(ReportGenerationError.notebookTakesNoReport(title: title, reason: refusal).localizedDescription)
            return nil
        }
        return ReportOptionsTarget(
            notebookID: notebookID,
            format: format,
            sourceIDs: sourceIDs,
            windowID: activeWindowState.id
        )
    }

    /// Whether a report can be made in the notebook: a live Notebook of this
    /// library whose team, if it has one, this account may write to.
    func canMakeReport(in notebookID: String) -> Bool {
        reportRefusal(notebookID: notebookID) == nil
    }

    /// Why no report can be made in a notebook, as the end of a sentence
    /// ("it is archived"); nil when one can. A report is a Doc filed in the
    /// notebook, so the notebook's rule for what it takes applies
    /// (`NotebookImportRefusal`).
    func reportRefusal(notebookID: String) -> String? {
        guard let record = notebook(id: notebookID), record.isNotebook else {
            return NotebookImportRefusal.missing.reason
        }
        let team = record.teamID.flatMap { self.team(id: $0) }
        return NotebookImportRefusal.refusal(for: record, team: team)?.reason
    }

    /// The sheet's Make: write the report the plan describes, then open it
    /// in the window Make was pressed in when that window still holds the
    /// notebook. Nil when it was stopped or failed (said in a toast).
    @discardableResult
    func makeReport(_ plan: ReportPlan, windowID: UUID?) async -> ReportResult? {
        await ReportGenerationCoordinator.shared.make(plan, windowID: windowID, in: self)
    }

    /// Stops a report still being written. Nothing is saved.
    func cancelReport(_ runID: String) {
        ReportGenerationCoordinator.shared.cancel(runID)
    }

    /// A Doc's report recipe ("Made from 6 sources · Briefing · …"), read
    /// from its body once per revision: an outputs row's menu line. Nil for
    /// a Doc that is not a report.
    func reportRecipe(_ artifactID: String) async -> ReportRecipe? {
        guard let artifact = artifacts.first(where: { $0.id == artifactID }) else { return nil }
        return await ReportGenerationCoordinator.shared.recipe(for: artifact, storage: storage)
    }
}
#endif
