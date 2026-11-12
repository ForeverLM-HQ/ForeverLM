// PDF download and paywall-to-PMC pipeline tests, live-network ones gated by an environment variable.

import Testing
import Foundation
import WebKit
@testable import ForeverLM

// MARK: - PDF Download Integration Tests

/// Live-network integration tests (arXiv, EuropePMC, NCBI, Unpaywall) are skipped
/// by default: they depend on external services whose data drifts over time (e.g.
/// EuropePMC's PMCID answer for a DOI can change) and whose availability flakes.
/// Run them manually by setting FOREVERLM_NETWORK_TESTS=1 in the test scheme's
/// environment variables (or the shell environment when invoking the test runner).
private let liveNetworkTestsEnabled = ProcessInfo.processInfo.environment["FOREVERLM_NETWORK_TESTS"] == "1"

@Suite("PDF Download Pipeline")
struct PDFDownloadTests {

    private func downloadAndVerifyPDF(from url: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destPath = tempDir.appendingPathComponent("test.pdf").path
        let service = SourceService()
        try await service.downloadPDF(from: url, to: destPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: destPath))
        // PDF magic bytes: %PDF-
        #expect(data.count > 100, "Downloaded file is too small")
        #expect(data.prefix(5) == Data([0x25, 0x50, 0x44, 0x46, 0x2D]), "File does not have PDF magic bytes")
    }

    @Test("Downloads arXiv PDF", .enabled(if: liveNetworkTestsEnabled))
    func arxivPDF() async throws {
        try await downloadAndVerifyPDF(from: "https://arxiv.org/pdf/2301.07041.pdf")
    }

    @Test("PMC lookup finds PDF URL for known PMCID", .enabled(if: liveNetworkTestsEnabled))
    func pmcLookupFindsPDF() async {
        // PepTune paper — PMC11703081
        let result = await PaperService.lookupPMCByPMCID(pmcid: "PMC11703081")
        #expect(result != nil, "PMC lookup returned nil")
        #expect(result?.pmcid == "PMC11703081")
        // Should find either a direct PDF URL or at least the PMCID for text fallback
        let hasPDF = result?.pdfURL != nil
        let hasPMCID = result?.pmcid != nil
        #expect(hasPDF || hasPMCID, "PMC lookup returned neither PDF URL nor PMCID")
    }

    @Test("PMC full text fetch works for known PMCID", .enabled(if: liveNetworkTestsEnabled))
    func pmcFullTextFetch() async {
        let text = await PaperService.fetchPMCFullText(pmcid: "PMC11703081")
        #expect(text != nil, "PMC full text fetch returned nil")
        if let text {
            #expect(text.count > 500, "PMC full text is suspiciously short: \(text.count) chars")
        }
    }

    @Test("PMC article URL returns nil from paperPDFURL (delegates to lookup)")
    func pmcURLReturnsNil() {
        // PMC URLs should NOT return a direct PDF URL — they use the EuropePMC lookup path
        let result = PaperService.paperPDFURL(from: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11703081/")
        #expect(result == nil)

        let result2 = PaperService.paperPDFURL(from: "https://pmc.ncbi.nlm.nih.gov/articles/PMC11703081/")
        #expect(result2 == nil)
    }

    @Test("Extracts PMC ID from various URL formats")
    func pmcIDExtraction() {
        #expect(PaperService.extractPMCID(from: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11703081/") == "PMC11703081")
        #expect(PaperService.extractPMCID(from: "https://pmc.ncbi.nlm.nih.gov/articles/PMC11703081/") == "PMC11703081")
        #expect(PaperService.extractPMCID(from: "https://pmc.ncbi.nlm.nih.gov/articles/PMC11703081") == "PMC11703081")
        #expect(PaperService.extractPMCID(from: "https://example.com/not-a-pmc-url") == nil)
    }

    @Test("Downloads PDF from direct URL with browser-like headers", .enabled(if: liveNetworkTestsEnabled))
    func downloadWithBrowserHeaders() async throws {
        // PNAS is open access and serves PDFs
        try await downloadAndVerifyPDF(from: "https://arxiv.org/pdf/2505.00784.pdf")
    }
}

// MARK: - Paywall → PMC → PDF Integration Tests

// Live-network suite: every test except the DOI extraction hits EuropePMC, NCBI,
// or Unpaywall. Skipped by default (remote data drifts — a July 2026 run showed
// EuropePMC returning a PMCID other than PMC6345342 for the DOI below); run with
// FOREVERLM_NETWORK_TESTS=1 in the test environment.
@Suite("Paywall to PMC Pipeline")
struct PaywallToPMCTests {

    // Use a Nature Methods paper known to be in PMC:
    // "Deep generative modeling for single-cell transcriptomics"
    // DOI: 10.1038/s41592-018-0229-2, PMCID: PMC6345342
    static let natureDOI = "10.1038/s41592-018-0229-2"
    static let natureURL = "https://www.nature.com/articles/s41592-018-0229-2"
    static let expectedPMCID = "PMC6345342"

    // -- Step 1: DOI extraction from paywalled URL --

    @Test("Extracts DOI from Nature URL")
    func extractDOIFromNature() {
        let doi = PaperService.extractDOI(from: Self.natureURL)
        #expect(doi == Self.natureDOI, "Expected DOI \(Self.natureDOI), got \(doi ?? "nil")")
    }

    @Test("Open-access lookup prefers a stored DOI over the landing URL")
    func openAccessLookupPrefersStoredDOI() {
        let doi = PaperService.openAccessLookupDOI(
            url: "https://publisher.example/article/opaque-id",
            storedDOI: "https://doi.org/10.1000/catalog-doi"
        )
        #expect(doi == "10.1000/catalog-doi")
    }

    @Test("Open-access lookup falls back to a DOI encoded in the URL")
    func openAccessLookupFallsBackToURL() {
        let doi = PaperService.openAccessLookupDOI(
            url: "https://doi.org/10.1000/url-doi",
            storedDOI: nil
        )
        #expect(doi == "10.1000/url-doi")
    }

    // -- Step 2: PMC lookup by DOI --

    @Test("EuropePMC finds PMCID for Nature DOI", .enabled(if: liveNetworkTestsEnabled))
    func pmcLookupByDOI() async {
        let result = await PaperService.lookupPMC(doi: Self.natureDOI)
        #expect(result != nil, "EuropePMC returned nil for DOI \(Self.natureDOI)")
        if let result {
            #expect(result.pmcid != nil, "EuropePMC returned no PMCID")
            #expect(result.pmcid == Self.expectedPMCID, "Expected \(Self.expectedPMCID), got \(result.pmcid ?? "nil")")
        }
    }

    @Test("EuropePMC lookup returns a PDF URL for Nature DOI", .enabled(if: liveNetworkTestsEnabled))
    func pmcLookupReturnsPDFURL() async {
        let result = await PaperService.lookupPMC(doi: Self.natureDOI)
        #expect(result != nil, "EuropePMC returned nil")
        if let result {
            #expect(result.pdfURL != nil, "EuropePMC returned PMCID \(result.pmcid ?? "?") but no PDF URL — this means the download will need BioC/efetch text fallback")
            if let pdfURL = result.pdfURL {
                #expect(pdfURL.hasPrefix("http"), "PDF URL is not an HTTP URL: \(pdfURL)")
            }
        }
    }

    // -- Step 3: PDF URL from EuropePMC is actually downloadable --

    @Test("PDF URL from EuropePMC actually serves a valid PDF", .enabled(if: liveNetworkTestsEnabled))
    func downloadPDFFromEuropePMCURL() async throws {
        let result = await PaperService.lookupPMC(doi: Self.natureDOI)
        guard let pdfURL = result?.pdfURL else {
            // No PDF URL from EuropePMC — check if text fallback would work instead
            if let pmcid = result?.pmcid {
                let text = await PaperService.fetchPMCFullText(pmcid: pmcid)
                #expect(text != nil, "No PDF URL and BioC text fallback also failed for \(pmcid)")
            } else {
                Issue.record("EuropePMC returned neither PDF URL nor PMCID for DOI \(Self.natureDOI)")
            }
            return
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destPath = tempDir.appendingPathComponent("test.pdf").path
        let service = SourceService()
        do {
            try await service.downloadPDF(from: pdfURL, to: destPath)
            let data = try Data(contentsOf: URL(fileURLWithPath: destPath))
            #expect(data.count > 100, "Downloaded file is too small (\(data.count) bytes)")
            #expect(data.prefix(5) == Data([0x25, 0x50, 0x44, 0x46, 0x2D]),
                    "File from \(pdfURL) does not have PDF magic bytes — got \(String(data: data.prefix(20), encoding: .utf8) ?? "binary")")
        } catch {
            Issue.record("Download from EuropePMC PDF URL failed: \(pdfURL) — \(error)")
        }
    }

    // -- Step 4: Unpaywall fallback --

    @Test("Unpaywall finds OA PDF for Nature DOI", .enabled(if: liveNetworkTestsEnabled))
    func unpaywallFindsPDF() async {
        let pdfURL = await PaperService.lookupUnpaywall(doi: Self.natureDOI)
        // Unpaywall may or may not have this — just log
        if let pdfURL {
            #expect(pdfURL.hasPrefix("http"), "Unpaywall PDF URL is not HTTP: \(pdfURL)")
        }
    }

    @Test("Unpaywall exposes every OA PDF candidate after the preferred URL")
    func unpaywallExposesAllPDFCandidates() {
        let json: [String: Any] = [
            "is_oa": true,
            "best_oa_location": [
                "host_type": "publisher",
                "url_for_pdf": "https://onlinelibrary.wiley.com/doi/pdfdirect/10.1002/advs.76740",
            ],
            "oa_locations": [
                [
                    "host_type": "publisher",
                    "url_for_pdf": "https://onlinelibrary.wiley.com/doi/pdfdirect/10.1002/advs.76740",
                ],
                [
                    "host_type": "repository",
                    "url_for_pdf": "https://www.biorxiv.org/content/biorxiv/early/2025/06/04/2025.06.04.657785.full.pdf",
                ],
                [
                    "host_type": "repository",
                    "url_for_pdf": "https://pmc.ncbi.nlm.nih.gov/articles/PMC13403736/pdf/ADVS-9999-e76740.pdf",
                ],
            ],
        ]

        let candidates = PaperService.unpaywallPDFURLs(from: json)

        #expect(candidates == [
            "https://onlinelibrary.wiley.com/doi/pdfdirect/10.1002/advs.76740",
            "https://www.biorxiv.org/content/biorxiv/early/2025/06/04/2025.06.04.657785.full.pdf",
            "https://pmc.ncbi.nlm.nih.gov/articles/PMC13403736/pdf/ADVS-9999-e76740.pdf",
        ])
    }

    @Test("Unpaywall rejects malformed candidates without discarding valid ones")
    func unpaywallFiltersMalformedPDFCandidates() {
        let json: [String: Any] = [
            "is_oa": true,
            "best_oa_location": [
                "host_type": "publisher",
                "url_for_pdf": "not a URL",
            ],
            "oa_locations": [
                ["url_for_pdf": "file:///tmp/paper.pdf"],
                ["url_for_pdf": "https://repository.example/paper.pdf"],
            ],
        ]

        #expect(PaperService.unpaywallPDFURLs(from: json) == [
            "https://repository.example/paper.pdf",
        ])
    }

    @Test("OA candidate pipeline reaches a readable copy after an inaccessible lead", .enabled(if: liveNetworkTestsEnabled))
    func openAccessCandidateFallbackDownloadsPasta() async throws {
        let sourceURL = "https://advanced.onlinelibrary.wiley.com/doi/full/10.1002/advs.76740"
        let alternatives = await PaperService.findOpenAccessAlternatives(
            url: sourceURL,
            title: "Pasta, a Versatile Transcriptomic Clock, Maps the Chemical and Genetic Determinants of Aging and Rejuvenation",
            doi: "10.1002/advs.76740"
        )
        #expect(alternatives.count > 1, "Expected multiple independent OA leads")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let destination = tempDir.appendingPathComponent("pasta.pdf")

        var downloadedFrom: String?
        var failures: [String] = []
        for alternative in alternatives {
            do {
                try await SourceService.shared.downloadPDF(
                    from: alternative.replacementURL,
                    to: destination.path
                )
                guard SourceService.canOpenPDF(at: destination.path) else {
                    throw SourceError.pdfReadFailed
                }
                downloadedFrom = alternative.replacementURL
                break
            } catch {
                failures.append("\(alternative.replacementURL): \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: destination)
            }
        }

        #expect(
            downloadedFrom != nil,
            "No discovered OA candidate returned a readable PDF: \(failures.joined(separator: "; "))"
        )
    }

    // -- Step 5: Text fallback when PDF is unavailable --

    @Test("BioC full text works as fallback for known PMCID", .enabled(if: liveNetworkTestsEnabled))
    func biocTextFallback() async {
        let text = await PaperService.fetchPMCFullText(pmcid: Self.expectedPMCID)
        #expect(text != nil, "BioC full text returned nil for \(Self.expectedPMCID)")
        if let text {
            #expect(text.count > 500, "BioC full text suspiciously short: \(text.count) chars")
        }
    }

    // -- Step 7: End-to-end — the replacement URL's PDF is downloadable --

    @Test("Replacement URL from findOpenAccessAlternatives leads to downloadable PDF", .enabled(if: liveNetworkTestsEnabled))
    func oaAlternativeDownloadsPDF() async throws {
        guard let alternative = await PaperService.findOpenAccessAlternatives(url: Self.natureURL, title: "Deep generative modeling").first else {
            Issue.record("No OA alternative found — can't test download")
            return
        }

        let replacementURL = alternative.replacementURL
        // The replacement URL is typically a PMC article URL — extract PMCID and do lookup
        var pdfURL: String?

        if let directPDF = PaperService.paperPDFURL(from: replacementURL) {
            pdfURL = directPDF
        } else if let pmcid = PaperService.extractPMCID(from: replacementURL) {
            // This is the exact path downloadPaperPDF takes
            let pmcResult = await PaperService.lookupPMCByPMCID(pmcid: pmcid)
            pdfURL = pmcResult?.pdfURL
            if pdfURL == nil, let pmcid = pmcResult?.pmcid {
                // No PDF — check text fallback
                let text = await PaperService.fetchPMCFullText(pmcid: pmcid)
                #expect(text != nil, "Replacement URL \(replacementURL) has no downloadable PDF and BioC text fallback failed for \(pmcid)")
                return  // Text fallback is acceptable
            }
        }

        guard let pdfURL else {
            Issue.record("Could not derive PDF URL from replacement URL: \(replacementURL)")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destPath = tempDir.appendingPathComponent("test.pdf").path
        let service = SourceService()
        do {
            try await service.downloadPDF(from: pdfURL, to: destPath)
            let data = try Data(contentsOf: URL(fileURLWithPath: destPath))
            #expect(data.count > 100, "Downloaded file too small: \(data.count) bytes from \(pdfURL)")
            #expect(data.prefix(5) == Data([0x25, 0x50, 0x44, 0x46, 0x2D]),
                    "Not a PDF from \(pdfURL) — first bytes: \(String(data: data.prefix(40), encoding: .utf8) ?? "binary")")
        } catch {
            Issue.record("PDF download failed from \(pdfURL) (via \(alternative.sourceName)): \(error)")
        }
    }

    // -- Step 8: PMCID-based lookup for direct PMC URL (non-paywalled PMC path) --

    @Test("Direct PMC URL → lookupPMCByPMCID → PDF download works end-to-end", .enabled(if: liveNetworkTestsEnabled))
    func directPMCURLPipeline() async throws {
        let pmcURL = "https://pmc.ncbi.nlm.nih.gov/articles/\(Self.expectedPMCID)/"

        // paperPDFURL should return nil for PMC URLs
        #expect(PaperService.paperPDFURL(from: pmcURL) == nil)

        // extractPMCID should work
        let pmcid = PaperService.extractPMCID(from: pmcURL)
        #expect(pmcid == Self.expectedPMCID)

        // lookupPMCByPMCID should find something
        guard let pmcid else { return }
        let result = await PaperService.lookupPMCByPMCID(pmcid: pmcid)
        #expect(result != nil, "lookupPMCByPMCID returned nil for \(pmcid)")

        guard let result else { return }

        if let pdfURL = result.pdfURL {
            // Try downloading the PDF
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let destPath = tempDir.appendingPathComponent("test.pdf").path
            let service = SourceService()
            do {
                try await service.downloadPDF(from: pdfURL, to: destPath)
                let data = try Data(contentsOf: URL(fileURLWithPath: destPath))
                #expect(data.prefix(5) == Data([0x25, 0x50, 0x44, 0x46, 0x2D]),
                        "Not a PDF from \(pdfURL)")
            } catch {
                Issue.record("PDF download from \(pdfURL) failed: \(error) — this is likely the bug causing 'Could not load PDF'")
            }
        } else if let pmcid = result.pmcid {
            // Text fallback should work
            let text = await PaperService.fetchPMCFullText(pmcid: pmcid)
            #expect(text != nil, "No PDF URL and BioC text fallback also failed for \(pmcid)")
        } else {
            Issue.record("lookupPMCByPMCID returned neither pdfURL nor pmcid")
        }
    }
}
