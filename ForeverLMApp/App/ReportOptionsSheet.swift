#if os(macOS)
import SwiftUI

/// The options the Studio column's Report tile opens first, and the second
/// tap that makes it (Gemini's two-click lesson): the format, the document a
/// feedback report is about, a focus or a custom report's instruction, which
/// sources it is written from and how — whole, from their ideas, or
/// condensed, named here rather than cut silently — and the price of the
/// writing. Make closes the sheet; the run shows as a pending row among the
/// Studio's outputs (`ReportRunsList`), and the made Doc opens in the
/// notebook's panes of this window.
///
/// Presented by `reportOptionsSheet()` on the Studio window, for the target
/// `StudioViewModel.presentReportOptions(notebookID:format:)` set.
struct ReportOptionsSheet: View {
    var vm: StudioViewModel
    let target: ReportOptionsTarget
    @Environment(\.dismiss) private var dismiss

    @State private var format: ReportFormat
    @State private var focus = ""
    @State private var instruction = ""
    /// Think first: what the learner thinks matters most, asked before the
    /// report when the notebook's level asks (`ReportTake`).
    @State private var take = ""
    /// The chosen document's id: a source's or a Doc's.
    @State private var subjectID: String?
    @State private var notebook: ReportNotebook?
    @State private var subjectDocument: ReportSubjectDocument?
    @State private var plan: ReportPlan?
    @State private var errorMessage: String?
    @State private var isLoading = true

    init(vm: StudioViewModel, target: ReportOptionsTarget) {
        self.vm = vm
        self.target = target
        _format = State(initialValue: target.format ?? .default)
    }

    private var subject: ReportSubject? {
        guard let subjectID, let notebook else { return nil }
        return notebook.subject(id: subjectID)
    }

    private var options: ReportOptions {
        ReportOptions(format: format, focus: focus, instruction: instruction, subject: subject, take: asksForTake ? take : "")
    }

    /// Whether Think first asks before this notebook's reports.
    private var asksForTake: Bool {
        ThinkFirst.asks(.report, notebookID: target.notebookID)
    }

    private var notebookTitle: String {
        notebook?.title ?? vm.notebook(id: target.notebookID)?.title ?? "Notebook"
    }

    /// The plan for the options on screen, and only that one: while a change
    /// of option is being re-planned, Make waits rather than make what the
    /// previous price described.
    private var currentPlan: ReportPlan? {
        guard let plan, plan.options == options else { return nil }
        return plan
    }

    /// Whether Make can run: a current plan, and nothing the format needs
    /// left to give.
    private var canMake: Bool {
        currentPlan != nil && options.gap == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Report").font(.headline)
                Spacer()
                Button("Make") { make() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canMake)
                    .accessibilityIdentifier("report-sheet.make")
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                if asksForTake {
                    takeField
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text("Notebook")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(notebookTitle).lineLimit(2)
                    }
                    GridRow {
                        Text("Format").foregroundStyle(.secondary)
                        Picker("Format", selection: $format) {
                            ForEach(ReportFormat.allCases) { format in
                                Text(format.label).tag(format)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("report-sheet.format")
                    }
                    if format.needsSubject {
                        GridRow {
                            Text("Document").foregroundStyle(.secondary)
                            subjectPicker
                        }
                    }
                    GridRow {
                        Text("Sources").foregroundStyle(.secondary)
                        sourcesLine
                    }
                    GridRow {
                        Text("Price").foregroundStyle(.secondary)
                        priceLine
                    }
                }

                textField
            }
            .padding(20)

            if isLoading || errorMessage != nil {
                Divider()
                SourcesReadingStatusRow(errorMessage: errorMessage)
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { await load() }
        .onChange(of: options) { _, _ in
            Task { await replan() }
        }
        .onChange(of: subjectID) { _, _ in
            Task { await loadSubjectDocumentIfNeeded() }
        }
    }

    // MARK: Lines

    /// The document a feedback report is about: one of the notebook's Docs,
    /// or one of the sources it is written from.
    @ViewBuilder
    private var subjectPicker: some View {
        Picker("Document", selection: $subjectID) {
            Text("Choose…").tag(String?.none)
            if let notebook {
                if !notebook.documents.isEmpty {
                    Section("Pages") {
                        ForEach(notebook.documents) { document in
                            Text(document.title).tag(String?.some(document.id))
                        }
                    }
                }
                if !notebook.sources.candidates.isEmpty {
                    Section("Sources") {
                        ForEach(notebook.sources.candidates, id: \.source.id) { candidate in
                            Text(vm.displayTitle(for: candidate.source)).tag(String?.some(candidate.source.id))
                        }
                    }
                }
            }
        }
        .labelsHidden()
        .frame(maxWidth: 360, alignment: .leading)
        .accessibilityIdentifier("report-sheet.document")
    }

    @ViewBuilder
    private var sourcesLine: some View {
        if let plan {
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.sourcesSummary)
                if let detail = Self.readingDetail(plan) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var priceLine: some View {
        if let plan {
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.writingCost.label)
                Text(plan.route.modelLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    /// Which sources are not read whole, and which are left out, by name:
    /// the sheet says what the report is written from.
    static func readingDetail(_ plan: ReportPlan) -> String? {
        var parts: [String] = []
        let ideas = plan.sources.filter { $0.readAs == .ideas }.map(\.candidate.source.title)
        let condensed = plan.sources.filter { $0.readAs == .condensed }.map(\.candidate.source.title)
        if !ideas.isEmpty { parts.append("From their ideas, to fit the model's window: \(ideas.joined(separator: "; ")).") }
        if !condensed.isEmpty { parts.append("Condensed, to fit: \(condensed.joined(separator: "; ")).") }
        if !plan.skipped.isEmpty {
            parts.append("Left out: " + plan.skipped.map { "\($0.title) (\($0.reason.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))))" }.joined(separator: "; ") + ".")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Think first's ask (docs/fences-and-think-first-design.md): the
    /// learner's own view, before ForeverLM's report. Left empty, the report
    /// is made as it always was.
    private var takeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What do you think matters most here?").font(.headline)
            TextField("Your take", text: $take, prompt: Text("In your words"), axis: .vertical)
                .textFieldStyle(.plain)
                .labelsHidden()
                .lineLimit(2...6)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("report-sheet.take")
    }

    /// The focus, or a custom report's instruction, which it needs.
    @ViewBuilder
    private var textField: some View {
        let needsInstruction = format.needsInstruction
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(needsInstruction ? "Instruction" : "Focus").font(.headline)
                if !needsInstruction {
                    Text("Optional").font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField(
                needsInstruction ? "Instruction" : "Focus",
                text: needsInstruction ? $instruction : $focus,
                prompt: Text(needsInstruction ? "What the report should be" : "What the report should focus on"),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .labelsHidden()
            .lineLimit(needsInstruction ? 2...6 : 1...3)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(needsInstruction ? "report-sheet.instruction" : "report-sheet.focus")
    }

    // MARK: Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            notebook = try await ReportGenerationCoordinator.loadNotebook(
                notebookID: target.notebookID,
                sourceIDs: target.sourceIDs,
                storage: vm.storage
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await replan()
    }

    /// The chosen Doc's text, read once it is chosen; then a new plan.
    private func loadSubjectDocumentIfNeeded() async {
        guard let notebook, let subject, subject.kind == .doc else { return }
        guard subjectDocument?.id != subject.id else { return }
        do {
            let loaded = try await ReportGenerationCoordinator.loadSubjectDocument(subject.id, in: notebook, storage: vm.storage)
            // A slower read for a document the learner has since changed is not theirs.
            guard subjectID == loaded.id else { return }
            subjectDocument = loaded
            await replan()
        } catch {
            plan = nil
            errorMessage = error.localizedDescription
        }
    }

    private func replan() async {
        guard let notebook else { return }
        let asked = options
        var document: ReportSubjectDocument?
        if let subject = asked.effectiveSubject, subject.kind == .doc {
            // Its text is still being read; the plan follows it.
            guard let loaded = subjectDocument, loaded.id == subject.id else { return }
            document = loaded
        }
        let request = ReportRequest(notebookID: target.notebookID, options: asked, sourceIDs: target.sourceIDs)
        do {
            let planned = try await ReportGenerationCoordinator.plan(notebook, request: request, subjectDocument: document)
            // A slower answer for options the learner has since changed is not theirs.
            guard planned.options == options else { return }
            plan = planned
            errorMessage = nil
        } catch {
            guard asked == options else { return }
            plan = nil
            errorMessage = error.localizedDescription
        }
    }

    private func make() {
        guard canMake, let plan = currentPlan else { return }
        if asksForTake {
            ThinkFirstTally.record(.report, answered: plan.options.trimmedTake != nil)
        }
        dismiss()
        let vm = vm
        let windowID = target.windowID
        Task {
            await vm.makeReport(plan, windowID: windowID)
        }
    }
}

/// A notebook's reports being written, where its outputs are listed: a row
/// per run, oldest first, a run an assistant started over MCP included. The
/// Studio column's outputs show these above the saved Docs; a saved report is
/// one of the Docs.
struct ReportRunsList: View {
    var vm: StudioViewModel
    let notebookID: String
    @ObservedObject private var writer = ReportGenerationCoordinator.shared

    var body: some View {
        ForEach(writer.runs(inNotebook: notebookID)) { run in
            ReportRunRow(vm: vm, run: run)
        }
    }
}

/// One report still being written, where the notebook lists its outputs:
/// its format, its stage and a Stop. Nothing is saved when it is stopped.
struct ReportRunRow: View {
    var vm: StudioViewModel
    let run: ReportGenerationCoordinator.Run

    var body: some View {
        HStack(spacing: 10) {
            NotebookStudioBadge(symbolName: run.format.symbolName, hue: NotebookStudioTile.report.hue)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.format.label).lineLimit(1)
                Text(run.stage.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            ProgressView().controlSize(.small)
            Button("Stop") { vm.cancelReport(run.id) }
                .buttonStyle(.hoverWash)
                .font(.callout)
                .accessibilityIdentifier("report-run.stop")
        }
        .contextMenu {
            Button("Stop Writing", systemImage: "stop.circle") { vm.cancelReport(run.id) }
        }
    }
}

extension View {
    /// Presents the report options sheet asked for in this Studio window
    /// (`StudioViewModel.presentReportOptions`), and in no other window.
    func reportOptionsSheet() -> some View {
        modifier(ReportOptionsSheetHost())
    }
}

private struct ReportOptionsSheetHost: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @ObservedObject private var coordinator = ReportGenerationCoordinator.shared

    private var target: Binding<ReportOptionsTarget?> {
        let windowID = windowState.id
        return Binding(
            get: { coordinator.optionsTarget(in: windowID) },
            set: { newValue in
                guard newValue == nil else { return }
                coordinator.dismissOptions(in: windowID)
            }
        )
    }

    func body(content: Content) -> some View {
        content.sheet(item: target) { target in
            ReportOptionsSheet(vm: vm, target: target)
        }
    }
}
#endif
