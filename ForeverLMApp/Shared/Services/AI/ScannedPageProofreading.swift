import Foundation

/// The pass a scanned book's OCR goes through before it becomes the book's
/// text: a model reads each page's picture beside the lines OCR read off it
/// and corrects the lines to what the page prints. Measured on a 400-page
/// physiology scan (2026-10-12), on-device OCR reads prose almost perfectly
/// but writes K⁺ as "K*", β as "B", 10⁻⁷ as "10-7" and glues reference
/// numbers to words; only the picture can say what was printed.
///
/// The model changes words and never the page: the lines stay where OCR found
/// them, one for one, so the text layer still lies over its print.
enum ScannedPageProofreading {
    /// Pages proofread at once. Each request carries one page's picture.
    static let concurrentPages = 6

    struct Reply: Decodable {
        let fixes: [String: String]
    }

    static func userPrompt(bookTitle: String, pageIndex: Int, pageCount: Int, lines: [RecognizedPDFLine]) -> String {
        var prompt = """
        Book: \(bookTitle)
        Page \(pageIndex + 1) of \(pageCount)

        OCR lines:
        """
        for (number, line) in lines.enumerated() {
            prompt += "\n\(number)\t\(line.text)"
        }
        return prompt
    }

    /// The page's lines with the model's fixes applied. A reply that names a
    /// line the page does not have, empties a line, or is not the JSON the
    /// prompt asks for is not an answer, and throws.
    static func applying(reply: String, to lines: [RecognizedPDFLine]) throws -> [RecognizedPDFLine] {
        let fixes = try decodedFixes(reply, lineCount: lines.count)
        var corrected = lines
        for (number, text) in fixes {
            corrected[number].text = text
        }
        return corrected
    }

    static func decodedFixes(_ reply: String, lineCount: Int) throws -> [Int: String] {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw AIError.invalidResponse
        }
        var fixes: [Int: String] = [:]
        for (key, value) in decoded.fixes {
            guard let number = Int(key.trimmingCharacters(in: .whitespaces)),
                  number >= 0, number < lineCount else {
                throw AIError.apiError("Scanned page proofreading named line \(key), which the page does not have.")
            }
            let corrected = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !corrected.isEmpty, !corrected.contains("\n") else {
                throw AIError.apiError("Scanned page proofreading returned line \(key) empty or split; lines are corrected one for one.")
            }
            fixes[number] = corrected
        }
        return fixes
    }

    #if os(macOS)
    /// Proofreads every page in `pages`, a few at a time. `progress` gets
    /// (pages proofread, pages to proofread). A page whose proofreading fails
    /// after the task's retries and backups fails the whole pass: the book is
    /// not imported with text nobody checked.
    static func proofread(
        _ pages: ScannedPDFPages,
        bookTitle: String,
        source: AIUsageSource,
        aiService: AIService,
        config: AITaskConfig,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [Int: [RecognizedPDFLine]] {
        let system = AITask.scannedPageProofreading.effectivePrompt ?? Prompts.scannedPageProofreading
        let pageIndices = pages.lines.keys.sorted()
        var corrected: [Int: [RecognizedPDFLine]] = [:]
        try await withThrowingTaskGroup(of: (Int, [RecognizedPDFLine]).self) { group in
            var next = 0
            func addNext() {
                guard next < pageIndices.count else { return }
                let pageIndex = pageIndices[next]
                next += 1
                let lines = pages.lines[pageIndex] ?? []
                let pictureURL = pages.pictureURL(forPage: pageIndex)
                group.addTask {
                    let picture = try Data(contentsOf: pictureURL)
                    let user = userPrompt(
                        bookTitle: bookTitle,
                        pageIndex: pageIndex,
                        pageCount: pages.pageCount,
                        lines: lines
                    )
                    let lineCount = lines.count
                    let reply = try await AIBackgroundRetry.run(config: config) { config in
                        try await aiService.call(
                            config: config,
                            system: system,
                            user: user,
                            maxTokens: max(1_000, lineCount * 120),
                            temperature: 0,
                            imageJPEGData: picture,
                            validateResponse: { reply in _ = try decodedFixes(reply, lineCount: lineCount) },
                            sourceTitle: "Page \(pageIndex + 1) · \(source.title)",
                            subjectID: source.id,
                            subjectType: source.type
                        )
                    }
                    let fixed = try applying(reply: reply, to: lines)
                    return (pageIndex, fixed)
                }
            }
            for _ in 0..<concurrentPages { addNext() }
            while let (pageIndex, lines) = try await group.next() {
                corrected[pageIndex] = lines
                progress(corrected.count, pageIndices.count)
                addNext()
            }
        }
        return corrected
    }
    #endif
}
