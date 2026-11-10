#if DEBUG
import AVFoundation
import SwiftUI

// Launch-argument-gated self-checks for XCUITest, which is the only way to
// drive the app on this machine (no Simulator.app, and the helper cannot
// inject touches). The voice-only UI has no reader, so "sources really sync"
// and "source text really extracts" are not visible in any screen the tests
// could assert on — this probe runs those exact production code paths
// (MobileCloudSourceCatalog, MobileCloudSourceTextStore) and publishes one
// machine-readable status line for the test to read.
//
// Never active in a normal launch: every check hides behind a launch argument
// that only the UI tests pass, and the whole file is compiled out of Release.
enum MobileUITestProbe {
    /// Catalog + text-extraction checks (free: CloudKit reads only).
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-foreverlm-uitest-probe")
    }

    /// Makes a bounded, billable multi-chunk TTS probe through the production
    /// managed route, then proves AVFoundation can decode every returned MP3.
    static var wantsTTSCheck: Bool {
        ProcessInfo.processInfo.arguments.contains("-foreverlm-uitest-tts")
    }

    /// Synthesizes one short, decoded sample with the first listed voice of
    /// every model in OpenRouter's live speech directory. Explicit and
    /// billable: only the focused XCUITest passes this argument.
    static var wantsAllTTSModelsCheck: Bool {
        ProcessInfo.processInfo.arguments.contains("-foreverlm-uitest-tts-all-models")
    }

    /// Skips catalog work for the focused TTS transport probe.
    static var isTTSOnly: Bool {
        ProcessInfo.processInfo.arguments.contains("-foreverlm-uitest-tts-only")
    }
}

/// Renders the probe verdict as a real (tiny) text element so it reliably
/// appears in the accessibility tree. Format, one line of key=value tokens:
/// `ok visible=2628 extracted=3/3 minChars=1834 signedIn=1`
/// or `fail <stage> <detail…>`.
struct MobileUITestProbeView: View {
    @State private var status = "running"

    var body: some View {
        Text(status)
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("uitest.probe.status")
            .task {
                let verdict = await Self.run()
                status = verdict
                Self.writeStatusFile(verdict)
            }
    }

    /// Mirrors the verdict to Caches/ForeverLM/uitest-probe.txt so the host
    /// can read the full numbers after a run — the test log only records
    /// pass/fail, not the label text.
    private static func writeStatusFile(_ verdict: String) {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return }
        let directory = caches.appendingPathComponent("ForeverLM", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(verdict.utf8).write(
            to: directory.appendingPathComponent("uitest-probe.txt"),
            options: .atomic
        )
    }

    @MainActor
    private static func run() async -> String {
        if (MobileUITestProbe.wantsTTSCheck || MobileUITestProbe.wantsAllTTSModelsCheck),
           MobileUITestProbe.isTTSOnly {
            let signedIn = await Task.detached(priority: .userInitiated) {
                ManagedAI.isSignedIn
            }.value
            guard signedIn else { return "fail tts not-signed-in" }
            let tts = MobileUITestProbe.wantsAllTTSModelsCheck
                ? await allTTSModelsCheck()
                : await ttsTransportCheck()
            return tts.hasPrefix("tts=ok") ? "ok \(tts)" : "fail \(tts)"
        }

        // 1. The catalog, exactly as the list loads it.
        let sources: [MobileCloudSource]
        do {
            sources = try await MobileCloudSourceCatalog.shared.loadSources()
        } catch {
            return "fail catalog \(error.localizedDescription)"
        }
        let visible = sources.filter { !$0.isArchived }
        guard !visible.isEmpty else {
            return "fail catalog empty"
        }

        // 1b. Notebooks ride the same zone pass. FOREVERLM_PROBE_NOTEBOOKS=1 dumps
        // every Notebook with its synced/pool source resolution — the direct
        // check that a Notebook made on the Mac reached this phone with its
        // sources reachable.
        let notebooks = (try? await MobileCloudSourceCatalog.shared.loadNotebooks()) ?? []
        if ProcessInfo.processInfo.environment["FOREVERLM_PROBE_NOTEBOOKS"] == "1" {
            let syncedIDs = Set(visible.map(\.id))
            var hasUnresolvedSources = false
            let lines = notebooks.map { notebook in
                let reachable = notebook.sourceIDs.filter(syncedIDs.contains).count
                hasUnresolvedSources = hasUnresolvedSources || reachable != notebook.sourceIDs.count
                return "\(notebook.title)=\(reachable)/\(notebook.sourceIDs.count)"
            }
            let outcome = hasUnresolvedSources ? "fail notebook-sources" : "ok"
            return "\(outcome) notebooks=\(notebooks.count) " + lines.joined(separator: " ;; ")
        }

        // 2. Text extraction, sampled per source type. Chat and quizzing are
        // only as good as the text behind them, and the types do not behave
        // alike — a paper carries extracted PDF text, a podcast carries a
        // transcript, a video its captions — so a paper-only check would hide
        // a whole category having no readable text on the phone at all.
        //
        // Per type: `perType` newest sources, majority required. A brand-new
        // source whose Mac-side extraction has not finished yet is normal, so
        // the bar is a majority of each type rather than every single fetch.
        // FOREVERLM_PROBE_SAMPLE=<n> widens the per-type sample for an audit.
        let perType = max(1, Int(ProcessInfo.processInfo.environment["FOREVERLM_PROBE_SAMPLE"] ?? "") ?? 2)
        let byType = Dictionary(grouping: visible, by: \.sourceType)
        guard !byType.isEmpty else { return "fail extract no-candidates" }

        var perTypeResults: [String] = []
        var failedTypes: [String] = []
        var minChars = Int.max
        var totalExtracted = 0
        var totalTried = 0
        var lastError = ""

        for sourceType in byType.keys.sorted() {
            let candidates = Array((byType[sourceType] ?? []).prefix(perType))
            guard !candidates.isEmpty else { continue }

            var extracted = 0
            for source in candidates {
                do {
                    let text = try await MobileCloudSourceTextStore.shared
                        .loadSourceText(sourceID: source.id)
                    // Text that exists but is too short to discuss is a
                    // failure of the same kind as no text at all.
                    guard text.count >= 200 else {
                        lastError = "\(sourceType)/\(source.title.prefix(30)): only \(text.count) chars"
                        continue
                    }
                    extracted += 1
                    minChars = min(minChars, text.count)
                } catch {
                    lastError = "\(sourceType)/\(source.title.prefix(30)): \(error.localizedDescription)"
                }
            }

            totalExtracted += extracted
            totalTried += candidates.count
            perTypeResults.append("\(sourceType):\(extracted)/\(candidates.count)")
            // Majority of the sample, and at least one, or the type is broken.
            if extracted * 2 < candidates.count || extracted == 0 {
                failedTypes.append(sourceType)
            }
        }

        guard failedTypes.isEmpty else {
            return "fail extract types=[\(failedTypes.joined(separator: ","))] "
                + "\(perTypeResults.joined(separator: " ")) last=\(lastError)"
        }

        // 3. Managed sign-in (keychain; never on the main actor).
        let signedIn = await Task.detached(priority: .userInitiated) {
            ManagedAI.isSignedIn
        }.value

        var tokens = [
            "ok",
            "visible=\(visible.count)",
            "extracted=\(totalExtracted)/\(totalTried)",
            "[\(perTypeResults.joined(separator: " "))]",
            "minChars=\(minChars == .max ? 0 : minChars)",
            "signedIn=\(signedIn ? 1 : 0)",
            // The account read behind the home screen's balance line. It fails
            // silently in the UI (a balance that will not load is no reason to
            // block someone from talking), so the probe is where a broken
            // account read becomes visible instead of just absent.
            "balance=\(await balanceToken())",
            "notebooks=\(notebooks.count)",
        ]

        // The newest Notebook's pool resolution: how many of its sources a
        // conversation in it could actually reach on this phone.
        if let newest = notebooks.first {
            let syncedIDs = Set(visible.map(\.id))
            let reachable = newest.sourceIDs.filter(syncedIDs.contains).count
            tokens.append("projScope=\(reachable)/\(newest.sourceIDs.count)")
        }

        return tokens.joined(separator: " ")
    }

    /// The managed account's remaining credit, or why it could not be read.
    private static func balanceToken() async -> String {
        do {
            let balance = try await ManagedAI.balance()
            return String(format: "%.4f", balance.usd)
        } catch {
            return "failed(\(error.localizedDescription.prefix(60)))"
        }
    }

    /// Exercises the same request builder, managed proxy, model, metering
    /// boundary, and audio decoder as source Listen without touching iCloud.
    private static func ttsTransportCheck() async -> String {
        do {
            let probeText = (1...32).map { index in
                "Narration health check sentence \(index) verifies ordered multi-chunk speech generation in the iOS emulator."
            }.joined(separator: " ")
            let responses = try await CloudArticleTTS.synthesizeProbe(probeText)
            guard responses.count >= 2 else {
                return "tts=chunking-failed(\(responses.count))"
            }

            var totalBytes = 0
            var totalDurationMS = 0
            var requestIDs = Set<String>()
            for (index, response) in responses.enumerated() {
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("foreverlm-tts-\(UUID().uuidString)-\(index).\(response.fileExtension)")
                defer { try? FileManager.default.removeItem(at: fileURL) }
                try response.data.write(to: fileURL, options: .atomic)

                let file = try AVAudioFile(forReading: fileURL)
                let sampleRate = file.processingFormat.sampleRate
                guard sampleRate > 0, file.length > 0 else {
                    return "tts=decode-empty(chunk=\(index + 1))"
                }
                let durationMS = Int((Double(file.length) / sampleRate * 1_000).rounded())
                guard durationMS >= 200 else {
                    return "tts=decode-too-short(chunk=\(index + 1),\(durationMS)ms)"
                }
                // The probe runs signed in on the managed rail, where every
                // chunk carries the proxy's receipt; an own-key chunk has none.
                guard let receipt = response.requestID else {
                    return "tts=no-receipt(chunk=\(index + 1))"
                }
                totalBytes += response.data.count
                totalDurationMS += durationMS
                requestIDs.insert(receipt)
            }
            guard requestIDs.count == responses.count else {
                return "tts=duplicate-receipt"
            }
            return "tts=ok chunks=\(responses.count) bytes=\(totalBytes) durationMs=\(totalDurationMS) receipts=\(requestIDs.count)"
        } catch {
            return "tts=failed(\(error.localizedDescription.prefix(180)))"
        }
    }

    /// Runs the production pick probe against every model currently offered,
    /// three at a time so a slow endpoint does not turn the audit into a
    /// serial half-hour wait. The probe validates the response format and
    /// decodes/transcodes the returned audio before it succeeds.
    private static func allTTSModelsCheck() async -> String {
        await OpenRouterAudioDirectory.prepare(.speech)
        let models = ArticleSpeechCatalog.models
        guard !models.isEmpty else { return "tts=all-empty" }

        var failures: [(String, String)] = []
        await withTaskGroup(of: (String, String?).self) { group in
            for (index, model) in models.enumerated() {
                if index >= 3, let result = await group.next(), let message = result.1 {
                    failures.append((result.0, message))
                }
                group.addTask {
                    do {
                        try await CloudArticleTTS.synthesizeQualificationProbe(
                            "ForeverLM speech model health check.",
                            modelID: model.id,
                            voiceID: model.defaultVoiceID ?? ""
                        )
                        return (model.id, nil)
                    } catch {
                        return (model.id, String(error.localizedDescription.prefix(120)))
                    }
                }
            }
            while let result = await group.next() {
                if let message = result.1 { failures.append((result.0, message)) }
            }
        }
        guard failures.isEmpty else {
            let detail = failures.map { "\($0.0)=\($0.1)" }.joined(separator: ";")
            return "tts=all-failed passed=\(models.count - failures.count)/\(models.count) \(detail)"
        }
        return "tts=ok models=\(models.count)/\(models.count)"
    }
}
#endif
