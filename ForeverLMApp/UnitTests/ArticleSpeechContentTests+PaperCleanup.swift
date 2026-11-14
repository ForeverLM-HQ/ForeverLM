// Article speech tests: paper speech plans, deletion audits and canonical cleanup.

import AVFoundation
import Foundation
import Testing
@testable import ForeverLM

extension ArticleSpeechContentTests {
    /// Two-column PDF order puts a table between the halves of a sentence
    /// (heard on 2026-09-09: "the number, length, perimeter, This table
    /// compares methods … and area of mitochondria are reduced in disease").
    /// The spoken table waits until the sentence it interrupted has ended.
    @Test("a table read inside a sentence waits until the sentence has ended")
    func tableSummaryInsideASentenceWaitsForTheSentence() throws {
        let blocks = [
            AIService.PaperContentBlock(
                id: "B000001",
                text: "Mitochondria morphology can be determined by electron microscopy, and the number, length, perimeter,"
            ),
            AIService.PaperContentBlock(
                id: "B000002",
                text: "Table 2 Comparison of methods | Respirometry | Comprehensive"
            ),
            AIService.PaperContentBlock(
                id: "B000003",
                text: "and area of mitochondria are reduced in disease."
            ),
            AIService.PaperContentBlock(
                id: "B000004",
                text: "Impaired mitochondrial morphology correlates with frailty."
            ),
        ]
        let plan = AIService.PaperSpeechAdaptationPlan(adaptations: [
            AIService.PaperSpeechAdaptation(
                blockIDs: ["B000002"],
                spokenText: "This table compares methods for measuring mitochondrial dysfunction."
            ),
        ])

        let narration = try PaperTextToSpeechPreparationService.reconstruct(
            blocks: blocks,
            applying: plan
        )

        let sentenceEnd = try #require(narration.range(of: "reduced in disease."))
        let summary = try #require(narration.range(of: "This table compares"))
        let nextParagraph = try #require(narration.range(of: "Impaired mitochondrial"))
        #expect(sentenceEnd.upperBound <= summary.lowerBound)
        #expect(summary.upperBound <= nextParagraph.lowerBound)
        #expect(!narration.contains("Table 2 Comparison"))
    }

    @Test("a table after a complete sentence is read in place")
    func tableSummaryAfterASentenceStaysInPlace() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Several methods are compared below."),
            AIService.PaperContentBlock(id: "B000002", text: "Table 1 | Method | Cost"),
            AIService.PaperContentBlock(id: "B000003", text: "Respirometry remains the reference."),
        ]
        let plan = AIService.PaperSpeechAdaptationPlan(adaptations: [
            AIService.PaperSpeechAdaptation(blockIDs: ["B000002"], spokenText: "This table lists each method and its cost."),
        ])

        let narration = try PaperTextToSpeechPreparationService.reconstruct(
            blocks: blocks,
            applying: plan
        )

        let summary = try #require(narration.range(of: "This table lists"))
        let following = try #require(narration.range(of: "Respirometry remains"))
        #expect(summary.upperBound <= following.lowerBound)
    }

    @Test("paper narration strips linked numeric and inline author citations without rewriting prose")
    func paperNarrationStripsInlineCitations() throws {
        let blocks = [
            AIService.PaperContentBlock(
                id: "B000001",
                text: "Aging is a mitochondrial disease1 (Brandt et al)."
            ),
            AIService.PaperContentBlock(
                id: "B000002",
                text: "CO2 increased by 12 percent in 2020."
            ),
        ]
        let response = """
        {"adaptations":[],"removeText":[
          {"blockID":"B000001","exactText":"1","occurrence":1},
          {"blockID":"B000001","exactText":" (Brandt et al)","occurrence":1}
        ]}
        """
        let plan = try AIService.validatedPaperSpeechAdaptationPlan(response, blocks: blocks)

        let narration = try PaperTextToSpeechPreparationService.reconstruct(
            blocks: blocks,
            applying: plan
        )

        #expect(narration == "Aging is a mitochondrial disease. CO2 increased by 12 percent in 2020.")
        #expect(!narration.contains("Brandt"))
        #expect(narration.contains("CO2"))
        #expect(narration.contains("12 percent"))
        #expect(narration.contains("2020"))
    }

    @Test("a citation that runs over PDF lines is removed a piece per line, and the sentence closes up")
    func paperNarrationStripsCitationsAcrossLines() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "microglia are hypothesized to drive early FDG-PET elevations"),
            AIService.PaperContentBlock(id: "B000002", text: "(Xiang et al. 2021; Zimmer et al. 2022; Brendel et al. 2016, 2017;"),
            AIService.PaperContentBlock(id: "B000003", text: "Gotzl et al. 2019; Mirzaei et al. 2016; Liu et al. 2015; Xiang"),
            AIService.PaperContentBlock(id: "B000004", text: "et al. 2022). Microglia undergo metabolic reprogramming (Hu"),
            AIService.PaperContentBlock(id: "B000005", text: "et al. 2022; Pan et al. 2022) in response to pathology."),
        ]
        let response = """
        {"adaptations":[],"relocations":[],"removeText":[
          {"blockID":"B000002","exactText":"(Xiang et al. 2021; Zimmer et al. 2022; Brendel et al. 2016, 2017;","occurrence":1},
          {"blockID":"B000003","exactText":"Gotzl et al. 2019; Mirzaei et al. 2016; Liu et al. 2015; Xiang","occurrence":1},
          {"blockID":"B000004","exactText":"et al. 2022)","occurrence":1},
          {"blockID":"B000004","exactText":" (Hu","occurrence":1},
          {"blockID":"B000005","exactText":"et al. 2022; Pan et al. 2022)","occurrence":1}
        ]}
        """
        let plan = try AIService.validatedPaperSpeechAdaptationPlan(response, blocks: blocks)
        #expect(plan.removeText.count == 5)

        let narration = try PaperTextToSpeechPreparationService.reconstruct(blocks: blocks, applying: plan)

        #expect(narration == "microglia are hypothesized to drive early FDG-PET elevations. Microglia undergo metabolic reprogramming in response to pathology.")
    }

    @Test("paper speech plan replaces a table with a concise explanation and preserves prose")
    func paperSpeechPlanReconstruction() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "The experiment compared three treatments."),
            AIService.PaperContentBlock(id: "B000002", text: "Table 1. Outcomes by treatment"),
            AIService.PaperContentBlock(id: "B000003", text: "Group Mean SD p"),
            AIService.PaperContentBlock(id: "B000004", text: "A 14.2 3.1 .004"),
            AIService.PaperContentBlock(id: "B000005", text: "B 10.1 2.8 .110"),
            AIService.PaperContentBlock(id: "B000006", text: "The treatment effect remained after adjustment."),
        ]
        let plan = AIService.PaperSpeechAdaptationPlan(adaptations: [
            AIService.PaperSpeechAdaptation(
                blockIDs: ["B000002", "B000003", "B000004", "B000005"],
                spokenText: "Table one compares outcomes across the treatment groups; group A has the strongest result."
            ),
        ])

        let narration = try PaperTextToSpeechPreparationService.reconstruct(
            blocks: blocks,
            applying: plan
        )

        #expect(narration.contains("The experiment compared three treatments."))
        #expect(narration.contains("Table one compares outcomes"))
        #expect(narration.contains("The treatment effect remained after adjustment."))
        #expect(!narration.contains("Group Mean SD p"))
        #expect(!narration.contains("14.2 3.1"))
    }

    @Test("paper speech plan finishes interrupted prose before a boxed sidebar")
    func paperSpeechPlanRelocatesInterruptingSidebar() throws {
        let blocks = [
            AIService.PaperContentBlock(
                id: "B000001",
                text: "R&D on direct-acting hepatitis C antiviral"
            ),
            AIService.PaperContentBlock(id: "B000002", text: "Box 1 | Antibacterial discovery"),
            AIService.PaperContentBlock(id: "B000003", text: "The box preserves its substantive case study."),
            AIService.PaperContentBlock(
                id: "B000004",
                text: "drugs was impractical until the invention of replicons"
            ),
            AIService.PaperContentBlock(
                id: "B000005",
                text: "that made reliable screening possible."
            ),
        ]
        let response = """
        {"adaptations":[],"relocations":[
          {"blockIDs":["B000002","B000003"],"insertAfterBlockID":"B000005"}
        ],"removeText":[]}
        """
        let plan = try AIService.validatedPaperSpeechAdaptationPlan(response, blocks: blocks)
        let narration = try PaperTextToSpeechPreparationService.reconstruct(
            blocks: blocks,
            applying: plan
        )

        #expect(
            narration.contains(
                "R&D on direct-acting hepatitis C antiviral drugs was impractical until the invention of replicons that made reliable screening possible."
            )
        )
        let paragraph = try #require(narration.range(of: "that made reliable screening possible."))
        let box = try #require(narration.range(of: "Box 1 | Antibacterial discovery"))
        #expect(paragraph.upperBound < box.lowerBound)
        #expect(narration.contains("The box preserves its substantive case study."))
    }

    @Test("paper speech plan rejects backward or self-anchored sidebar moves")
    func paperSpeechRelocationValidation() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Main prose."),
            AIService.PaperContentBlock(id: "B000002", text: "Box heading"),
            AIService.PaperContentBlock(id: "B000003", text: "Box body."),
            AIService.PaperContentBlock(id: "B000004", text: "Main continuation."),
        ]
        let response = """
        {"adaptations":[],"relocations":[
          {"blockIDs":["B000002","B000003"],"insertAfterBlockID":"B000004"},
          {"blockIDs":["B000001"],"insertAfterBlockID":"B000001"},
          {"blockIDs":["B000004"],"insertAfterBlockID":"B000001"},
          {"blockIDs":["B999999"],"insertAfterBlockID":"B000004"}
        ],"removeText":[]}
        """

        let plan = try AIService.validatedPaperSpeechAdaptationPlan(response, blocks: blocks)
        #expect(plan.relocations == [
            AIService.PaperSpeechRelocation(
                blockIDs: ["B000002", "B000003"],
                insertAfterBlockID: "B000004"
            ),
        ])
    }

    @Test("paper speech plan validation rejects unsafe block ranges")
    func paperSpeechPlanValidation() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Prose before."),
            AIService.PaperContentBlock(id: "B000002", text: "Table header"),
            AIService.PaperContentBlock(id: "B000003", text: "Table row"),
            AIService.PaperContentBlock(id: "B000004", text: "Prose after."),
        ]
        let response = """
        {"adaptations":[
          {"blockIDs":["B000002","B000003"],"spokenText":"The table reports one comparison."},
          {"blockIDs":["B000001","B000004"],"spokenText":"Noncontiguous and unsafe."},
          {"blockIDs":["B999999"],"spokenText":"Unknown."},
          {"blockIDs":["B000003"],"spokenText":"Overlapping."}
        ]}
        """

        let plan = try AIService.validatedPaperSpeechAdaptationPlan(response, blocks: blocks)

        #expect(plan.adaptations == [
            AIService.PaperSpeechAdaptation(
                blockIDs: ["B000002", "B000003"],
                spokenText: "The table reports one comparison."
            ),
        ])
    }

    @Test("paper deletion-plan validation conservatively normalizes unsafe entries")
    func paperDeletionPlanValidation() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Authors"),
            AIService.PaperContentBlock(id: "B000002", text: "A result [12] remains."),
            AIService.PaperContentBlock(id: "B000003", text: "References")
        ]
        #expect(
            try AIService.validatedPaperContentDeletionPlan(
                #"{"removeBlocks":["B000001","B000003"],"removeText":[]}"#,
                blocks: blocks
            ).removeBlocks == ["B000001", "B000003"]
        )
        #expect(
            try AIService.validatedPaperContentDeletionPlan(
                #"{"removeBlocks":["B999999"],"removeText":[]}"#,
                blocks: blocks
            ).removeBlocks.isEmpty
        )
        #expect(
            try AIService.validatedPaperContentDeletionPlan(
                #"{"removeBlocks":["B000001","B000001"],"removeText":[]}"#,
                blocks: blocks
            ).removeBlocks == ["B000001"]
        )
        #expect(
            try AIService.validatedPaperContentDeletionPlan(
                "```json\n{\"removeBlocks\":[],\"removeText\":[]}\n```",
                blocks: blocks
            ) == .empty
        )
        let oversizedInlineHunk = String(repeating: "x", count: 161)
        #expect(
            try AIService.validatedPaperContentDeletionPlan(
                "{\"removeBlocks\":[],\"removeText\":[{\"blockID\":\"B000002\",\"exactText\":\"\(oversizedInlineHunk)\",\"occurrence\":1}]}",
                blocks: blocks
            ).removeText.isEmpty
        )
        #expect(
            try AIService.validatedPaperContentDeletionPlan(
                #"{"removeBlocks":[],"removeText":[{"blockID":"B000002","exactText":" [12]","occurrence":1},{"blockID":"B000002","exactText":"not verbatim","occurrence":1}]}"#,
                blocks: blocks
            ).removeText == [
                AIService.PaperContentTextDeletion(
                    blockID: "B000002",
                    exactText: " [12]",
                    occurrence: 1
                )
            ]
        )
        let relocationPlan = try AIService.validatedPaperContentDeletionPlan(
            #"{"removeBlocks":[],"relocations":[{"blockIDs":["B000002"],"insertAfterBlockID":"B000003"},{"blockIDs":["B000003"],"insertAfterBlockID":"B000001"}],"removeText":[]}"#,
            blocks: blocks
        )
        #expect(relocationPlan.relocations == [
            AIService.PaperSpeechRelocation(
                blockIDs: ["B000002"],
                insertAfterBlockID: "B000003"
            )
        ])

        let boxBlocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Box 1 | Preserved structure"),
            AIService.PaperContentBlock(id: "B000002", text: "Substantive Box body."),
        ]
        let boxPlan = try AIService.validatedPaperContentDeletionPlan(
            #"{"removeBlocks":["B000001"],"relocations":[],"keepInPlaceBoxHeadingIDs":["B000001"],"removeText":[{"blockID":"B000001","exactText":"Box 1 | ","occurrence":1}]}"#,
            blocks: boxBlocks
        )
        #expect(boxPlan.removeBlocks.isEmpty)
        #expect(boxPlan.removeText.isEmpty)
        #expect(boxPlan.keepInPlaceBoxHeadingIDs == ["B000001"])
    }

    @Test("paper deletion diffs remove blocks and exact inline noise without rewriting prose")
    func paperDeletionPlanReconstruction() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "A Useful Paper"),
            AIService.PaperContentBlock(id: "B000002", text: "The abstract [12] remains byte-for-byte."),
            AIService.PaperContentBlock(id: "B000003", text: "The substantive body also remains byte-for-byte."),
            AIService.PaperContentBlock(id: "B000004", text: "Publisher boilerplate")
        ]
        let clean = try PaperContentPreparationService.reconstruct(
            title: "A Useful Paper",
            blocks: blocks,
            applying: AIService.PaperContentDeletionPlan(
                removeBlocks: ["B000001", "B000004"],
                removeText: [
                    AIService.PaperContentTextDeletion(
                        blockID: "B000002",
                        exactText: " [12]",
                        occurrence: 1
                    )
                ]
            )
        )
        #expect(
            clean == "A Useful Paper\n\nThe abstract remains byte-for-byte.\nThe substantive body also remains byte-for-byte."
        )

        let preserved = try PaperContentPreparationService.reconstruct(
            title: "A Useful Paper",
            blocks: blocks,
            applying: AIService.PaperContentDeletionPlan(
                removeBlocks: ["B000001", "B000002", "B000003", "B000004"],
                removeText: []
            )
        )
        #expect(
            preserved == "A Useful Paper\n\nA Useful Paper\nThe abstract [12] remains byte-for-byte.\nThe substantive body also remains byte-for-byte.\nPublisher boilerplate"
        )
        #expect(throws: CanonicalContentCleanupContractError.self) {
            try PaperContentPreparationService.reconstruct(
                title: "A Useful Paper",
                blocks: blocks,
                applying: AIService.PaperContentDeletionPlan(
                    removeBlocks: ["B000001", "B000004"],
                    removeText: [
                        AIService.PaperContentTextDeletion(
                            blockID: "B000002",
                            exactText: "not verbatim",
                            occurrence: 1
                        )
                    ]
                )
            )
        }
    }

    /// The 2026-09-23 Cell paper: a deletion run that starts at References and
    /// runs on through the STAR★Methods printed after them.
    private static let methodsAfterReferencesBlocks = [
        AIService.PaperContentBlock(id: "B000001", text: "Cell 189, 4581–4593, July 23, 2026"),
        AIService.PaperContentBlock(id: "B000002", text: "Treating cells with nocodazole disrupted the microtubule network."),
        AIService.PaperContentBlock(id: "B000003", text: "REFERENCES"),
        AIService.PaperContentBlock(id: "B000004", text: "1. Maritan, M., Autin, L., and Goodsell, D.S. (2022). J. Mol. Biol. 434, 167351."),
        AIService.PaperContentBlock(id: "B000005", text: "KEY RESOURCES TABLE"),
        AIService.PaperContentBlock(id: "B000006", text: "Nocodazole MedChemExpress Cat#HY-13520"),
        AIService.PaperContentBlock(id: "B000007", text: "Cal27 cells were cultured in DMEM with 10% FBS."),
    ]

    @Test("deletion check sees each maximal deleted run with the kept block on either side")
    func deletionAuditRunsCarryTheirKeptNeighbours() {
        let blocks = Self.methodsAfterReferencesBlocks
        let runs = PaperContentPreparationService.deletionAuditRuns(
            blocks: blocks,
            removing: ["B000001", "B000003", "B000004", "B000005", "B000006", "B000007"]
        )
        #expect(runs == [
            AIService.PaperContentDeletionAuditRun(
                keptBefore: nil,
                removed: [blocks[0]],
                keptAfter: blocks[1]
            ),
            AIService.PaperContentDeletionAuditRun(
                keptBefore: blocks[1],
                removed: Array(blocks[2...6]),
                keptAfter: nil
            ),
        ])
        #expect(PaperContentPreparationService.deletionAuditRuns(blocks: blocks, removing: []).isEmpty)
    }

    @Test("deletion check restores only blocks it was shown as deletions")
    func deletionAuditValidation() throws {
        let blocks = Self.methodsAfterReferencesBlocks
        let runs = PaperContentPreparationService.deletionAuditRuns(
            blocks: blocks,
            removing: ["B000003", "B000004", "B000005", "B000006", "B000007"]
        )
        // B000002 is context, never deleted; B000099 was never shown.
        let restored = try AIService.validatedPaperContentDeletionAudit(
            #"{"keepBlocks":["B000005","B000006","B000007","B000002","B000099"]}"#,
            runs: runs
        )
        #expect(restored == ["B000005", "B000006", "B000007"])
        #expect(try AIService.validatedPaperContentDeletionAudit(
            "```json\n{\"keepBlocks\":[]}\n```",
            runs: runs
        ).isEmpty)
        // The cleanup asks again on exactly this message, so it must not drift.
        for reply in [#"{"removeBlocks":["B000003"]}"#, "", "I kept everything."] {
            do {
                _ = try AIService.validatedPaperContentDeletionAudit(reply, runs: runs)
                Issue.record("A reply that is not a deletion check was accepted: \(reply)")
            } catch AIError.apiError(let message) {
                #expect(message == AIService.invalidPaperContentDeletionAuditMessage)
            }
        }

        let plan = AIService.PaperContentDeletionPlan(
            removeBlocks: ["B000001", "B000003", "B000004", "B000005", "B000006", "B000007"]
                .filter { !restored.contains($0) },
            removeText: []
        )
        let clean = try PaperContentPreparationService.reconstruct(
            title: "Whole-cell digital twins",
            blocks: blocks,
            applying: plan
        )
        #expect(clean == """
        Whole-cell digital twins

        Treating cells with nocodazole disrupted the microtubule network.
        KEY RESOURCES TABLE
        Nocodazole MedChemExpress Cat#HY-13520
        Cal27 cells were cultured in DMEM with 10% FBS.
        """)
    }

    @Test("deletion check request shows the deletions and their context, and splits only past the window")
    func deletionAuditRequestChunking() throws {
        let blocks = Self.methodsAfterReferencesBlocks
        let runs = PaperContentPreparationService.deletionAuditRuns(
            blocks: blocks,
            removing: ["B000001", "B000003", "B000004", "B000005", "B000006", "B000007"]
        )
        let request = AIService.paperContentDeletionAuditRequest(
            sourceTitle: "Whole-cell digital twins",
            sourceType: .paper,
            runs: runs,
            chunkIndex: 0,
            chunkCount: 1
        )
        #expect(request.system == Prompts.paperContentDeletionAudit)
        #expect(request.user.contains(#"{"keptBefore":null,"delete":["#))
        #expect(request.user.contains(#""keptAfter":null}"#))
        #expect(request.user.contains("Cat#HY-13520"))

        #expect(try PaperContentPreparationService.deletionAuditRequestChunks(
            sourceTitle: "Whole-cell digital twins",
            sourceType: .paper,
            runs: runs,
            inputBudget: nil
        ) == [runs])

        let scaffold = AIService.paperContentDeletionAuditRequest(
            sourceTitle: "Whole-cell digital twins",
            sourceType: .paper,
            runs: [],
            chunkIndex: 999_998,
            chunkCount: 999_999
        ).inputCharacterCount
        let longestRun = AIService.paperContentDeletionAuditSerializedRun(runs[1]).count
        let chunks = try PaperContentPreparationService.deletionAuditRequestChunks(
            sourceTitle: "Whole-cell digital twins",
            sourceType: .paper,
            runs: runs,
            inputBudget: scaffold + longestRun * 3 / 4
        )
        #expect(chunks.count > 1)
        // Every deleted block is still judged, once, in document order.
        #expect(chunks.flatMap { $0.flatMap(\.removed) } == runs.flatMap(\.removed))
        for chunk in chunks {
            let size = AIService.paperContentDeletionAuditRequest(
                sourceTitle: "Whole-cell digital twins",
                sourceType: .paper,
                runs: chunk,
                chunkIndex: 0,
                chunkCount: chunks.count
            ).inputCharacterCount
            #expect(size <= scaffold + longestRun * 3 / 4)
        }
        let parts = chunks.flatMap { $0 }.filter { $0.removed.contains(blocks[2]) || $0.removed.contains(blocks[6]) }
        #expect(parts.first?.keptBefore == blocks[1])
        #expect(parts.last?.keptAfter == nil)
    }

    @Test("cleanup splits only when the complete request exceeds model context")
    func cleanupSplitsOnlyForActualModelContextLimit() throws {
        let blocks = (1...100).map { index in
            AIService.PaperContentBlock(
                id: String(format: "B%06d", index),
                text: String(repeating: "x", count: 800)
            )
        }
        let title = "A long context-aware paper"

        let largeWindowChunks = try PaperContentPreparationService.cleanupRequestChunks(
            system: Prompts.paperNarrationPreparation,
            sourceTitle: title,
            sourceType: .paper,
            blocks: blocks,
            provider: .openai,
            model: "gpt-5.6-luna"
        )
        #expect(largeWindowChunks == [blocks])

        let smallWindowChunks = try PaperContentPreparationService.cleanupRequestChunks(
            system: Prompts.paperNarrationPreparation,
            sourceTitle: title,
            sourceType: .paper,
            blocks: blocks,
            provider: .cerebras,
            model: "llama3.1-8b"
        )
        #expect(smallWindowChunks.count > 1)
        #expect(smallWindowChunks.flatMap { $0 } == blocks)

        let inputBudget = try #require(AIService.inputCharacterBudget(
            provider: .cerebras,
            model: "llama3.1-8b",
            requestedMaxTokens: AIService.paperContentDeletionMaxTokens
        ))
        for (index, chunk) in smallWindowChunks.enumerated() {
            let request = AIService.paperContentDeletionRequest(
                system: Prompts.paperNarrationPreparation,
                sourceTitle: title,
                sourceType: .paper,
                blocks: chunk,
                chunkIndex: index,
                chunkCount: smallWindowChunks.count
            )
            #expect(request.inputCharacterCount <= inputBudget)
        }
    }

    @Test("oversized cleanup requests identify their chunk in usage logs")
    func cleanupChunkUsageTitleIsVisible() {
        #expect(
            AIService.paperContentDeletionUsageTitle(
                sourceTitle: "A Paper",
                chunkIndex: 0,
                chunkCount: 1
            ) == "A Paper"
        )
        #expect(
            AIService.paperContentDeletionUsageTitle(
                sourceTitle: "A Paper",
                chunkIndex: 1,
                chunkCount: 3
            ) == "Chunk 2/3 · A Paper"
        )
        let request = AIService.paperContentDeletionRequest(
            system: Prompts.paperNarrationPreparation,
            sourceTitle: "A Paper",
            sourceType: .paper,
            blocks: [AIService.PaperContentBlock(id: "B000001", text: "Body")],
            chunkIndex: 1,
            chunkCount: 3
        )
        #expect(request.user.contains("This is Chunk 2/3"))
    }

    @Test("canonical cleanup finishes Scannell main prose before Box 1")
    func canonicalCleanupRelocatesScannellBoxAfterInterruptedParagraph() throws {
        let blocks = [
            AIService.PaperContentBlock(
                id: "B000346",
                text: "R&D on direct-acting hepatitis C antiviral"
            ),
            AIService.PaperContentBlock(
                id: "B000347",
                text: "Box 1 | 1930s decision tool quality beat 1990s decision tool quantity in antibacterials"
            ),
            AIService.PaperContentBlock(
                id: "B000348",
                text: "Domagk tested drug candidates against Streptococcus haemolyticus."
            ),
            AIService.PaperContentBlock(
                id: "B000449",
                text: "The box concludes with the consequences for antibacterial screening."
            ),
            AIService.PaperContentBlock(
                id: "B000452",
                text: "drugs was impractical until the invention of replicons that made reliable screening possible."
            ),
            AIService.PaperContentBlock(
                id: "B000453",
                text: "The next main-text paragraph starts here."
            ),
        ]
        let response = """
        {"removeBlocks":[],"relocations":[
          {"blockIDs":["B000347","B000348","B000449"],"insertAfterBlockID":"B000452"}
        ],"removeText":[]}
        """
        let plan = try AIService.validatedPaperContentDeletionPlan(response, blocks: blocks)
        let clean = try PaperContentPreparationService.reconstruct(
            title: "Predictive validity in drug discovery: what it is, why it matters and how to improve it",
            blocks: blocks,
            applying: plan
        )

        let completedParagraph = try #require(
            clean.range(of: "R&D on direct-acting hepatitis C antiviral\ndrugs was impractical")
        )
        let box = try #require(clean.range(of: "Box 1 |"))
        let nextParagraph = try #require(clean.range(of: "The next main-text paragraph"))
        #expect(completedParagraph.upperBound < box.lowerBound)
        #expect(box.lowerBound < nextParagraph.lowerBound)
        #expect(clean.contains("Domagk tested drug candidates"))
    }

    @Test("compact sidebar boundaries expand to the complete exact box interval")
    func compactSidebarBoundariesExpandDeterministically() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Main fragment"),
            AIService.PaperContentBlock(id: "B000002", text: "Box 1 | Case study"),
            AIService.PaperContentBlock(id: "B000003", text: "Complete box body"),
            AIService.PaperContentBlock(id: "B000004", text: "main prose resumes here"),
            AIService.PaperContentBlock(id: "B000005", text: "and finishes here."),
        ]
        let response = """
        {"removeBlocks":[],"relocations":[{
          "blockIDs":["B000002"],
          "resumeAtBlockID":"B000004",
          "insertAfterBlockID":"B000005"
        }],"removeText":[]}
        """

        let plan = try AIService.validatedPaperContentDeletionPlan(response, blocks: blocks)
        #expect(plan.relocations == [
            AIService.PaperSpeechRelocation(
                blockIDs: ["B000002", "B000003"],
                insertAfterBlockID: "B000005"
            )
        ])
    }

    @Test("Box relocation survives deletion of noise inside its exact range")
    func compactSidebarRelocationCanContainRemovedNoise() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "R&D on direct-acting hepatitis C antiviral"),
            AIService.PaperContentBlock(id: "B000002", text: "Box 1 | Antibacterial discovery"),
            AIService.PaperContentBlock(id: "B000003", text: "Downloaded from publisher header"),
            AIService.PaperContentBlock(id: "B000004", text: "Substantive Box body."),
            AIService.PaperContentBlock(id: "B000005", text: "drugs was impractical until replicons existed."),
        ]
        let response = """
        {"removeBlocks":["B000003"],"relocations":[{
          "blockIDs":["B000002"],
          "resumeAtBlockID":"B000005",
          "insertAfterBlockID":"B000005"
        }],"removeText":[]}
        """

        let plan = try AIService.validatedPaperContentDeletionPlan(response, blocks: blocks)
        #expect(plan.relocations.first?.blockIDs == ["B000002", "B000003", "B000004"])
        let clean = try PaperContentPreparationService.reconstruct(
            title: "Predictive validity",
            blocks: blocks,
            applying: plan
        )
        #expect(clean.contains("antiviral\ndrugs was impractical until replicons existed.\nBox 1"))
        #expect(!clean.contains("Downloaded from publisher header"))
        #expect(clean.contains("Substantive Box body."))
    }

    @Test("compact sidebar cleanup rejects a body-line start")
    func compactSidebarCleanupRejectsBodyLineStart() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Main fragment"),
            AIService.PaperContentBlock(id: "B000002", text: "Box 1 | Case study"),
            AIService.PaperContentBlock(id: "B000003", text: "Box body"),
            AIService.PaperContentBlock(id: "B000004", text: "main prose resumes"),
            AIService.PaperContentBlock(id: "B000005", text: "and finishes."),
        ]
        let response = #"{"removeBlocks":[],"relocations":[{"blockIDs":["B000003"],"resumeAtBlockID":"B000004","insertAfterBlockID":"B000005"}],"removeText":[]}"#
        let plan = try AIService.validatedPaperContentDeletionPlan(response, blocks: blocks)
        #expect(plan.relocations.isEmpty)
    }

    @Test("full-document cleanup explicitly classifies every Box without punctuation guesses")
    func fullDocumentCleanupClassifiesEveryBoxSemantically() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "causal relationship between target and disease)"),
            AIService.PaperContentBlock(id: "B000002", text: "Box 1 | Complete bullet follows"),
            AIService.PaperContentBlock(id: "B000003", text: "Substantive first Box body."),
            AIService.PaperContentBlock(id: "B000004", text: "The next main-text paragraph."),
            AIService.PaperContentBlock(id: "B000005", text: "attributes of being complete, consistent,"),
            AIService.PaperContentBlock(id: "B000006", text: "Box 2 | Interrupting sidebar"),
            AIService.PaperContentBlock(id: "B000007", text: "Substantive second Box body."),
            AIService.PaperContentBlock(id: "B000008", text: "enduring and available."),
            AIService.PaperContentBlock(id: "B000009", text: "volume 20 | January 2021 | 69"),
            AIService.PaperContentBlock(id: "B000010", text: "Box 3 | Follows a page header"),
        ]

        #expect(
            PaperContentPreparationService.sidebarHeadingIDs(in: blocks)
                == Set(["B000002", "B000006", "B000010"])
        )
        let response = """
        {"removeBlocks":[],"relocations":[{
          "blockIDs":["B000006"],
          "resumeAtBlockID":"B000008",
          "insertAfterBlockID":"B000008"
        }],"keepInPlaceBoxHeadingIDs":["B000002","B000010"],"removeText":[]}
        """
        let plan = try AIService.validatedPaperContentDeletionPlan(response, blocks: blocks)
        #expect(plan.keepInPlaceBoxHeadingIDs == ["B000002", "B000010"])
        try PaperContentPreparationService.validateSidebarDecisions(
            in: blocks,
            applying: plan
        )

        let omittedDecision = try AIService.validatedPaperContentDeletionPlan(
            response.replacingOccurrences(
                of: #""B000002","B000010""#,
                with: #""B000002""#
            ),
            blocks: blocks
        )
        #expect(throws: AIError.self) {
            try PaperContentPreparationService.validateSidebarDecisions(
                in: blocks,
                applying: omittedDecision
            )
        }

        let contradictoryDecision = try AIService.validatedPaperContentDeletionPlan(
            response.replacingOccurrences(
                of: #""B000002","B000010""#,
                with: #""B000002","B000006","B000010""#
            ),
            blocks: blocks
        )
        #expect(throws: AIError.self) {
            try PaperContentPreparationService.validateSidebarDecisions(
                in: blocks,
                applying: contradictoryDecision
            )
        }
    }

    @Test("article cleanup allows boilerplate-heavy web pages")
    func articleCleanupAllowsBoilerplateHeavyWebPages() throws {
        var blocks: [AIService.PaperContentBlock] = []
        var removeBlocks: [String] = []
        for index in 1...80 {
            let id = String(format: "B%06d", index)
            blocks.append(
                AIService.PaperContentBlock(
                    id: id,
                    text: "Patreon navigation, subscription prompt, related links, footer, and site chrome \(index)."
                )
            )
            removeBlocks.append(id)
        }
        blocks.append(
            AIService.PaperContentBlock(
                id: "B000081",
                text: "Preparatory notes for a manifesto begin with an actual substantive claim about the notebook, its audience, and why the argument matters."
            )
        )
        blocks.append(
            AIService.PaperContentBlock(
                id: "B000082",
                text: "The next note develops the premise in concrete terms, preserving the source prose exactly instead of summarizing or rewriting it."
            )
        )

        let clean = try PaperContentPreparationService.reconstruct(
            title: "Preparatory notes for a manifesto | Patreon",
            blocks: blocks,
            applying: AIService.PaperContentDeletionPlan(
                removeBlocks: removeBlocks,
                removeText: []
            )
        )

        #expect(clean.contains("Preparatory notes for a manifesto begin"))
        #expect(clean.contains("The next note develops the premise"))
        #expect(!clean.contains("Patreon navigation"))
    }

    /// The stored extraction of a locked Patreon post, verbatim: 29 lines of
    /// navigation, counters, and subscription prompts around a single 143-character
    /// teaser. Cleanup removed exactly the right 29 lines and was still rejected,
    /// because an absolute retained-character floor cannot be satisfied by a page
    /// that never contained more body than this.
    @Test("article cleanup keeps a paywall teaser shorter than any absolute floor")
    func articleCleanupKeepsShortPaywallTeaser() throws {
        let joinPrompt = """
            To access this whole post, join Patreon today. When you become a member, \
            you get instant access to exclusive posts and benefits.
            """
        let noise: [String] = [
            "Preparatory notes for a manifesto | Patreon", "Skip navigation",
            "Home", "Posts", "Collections", "Membership",
            "Home", "Posts", "Collections", "Membership",
            "Become a member", "Preparatory notes for a manifesto",
            "Andy Matuschak", "May 31, 2025", "New", "Join to unlock",
            "45", "9", "Share", "Locked", joinPrompt,
            "Join to unlock", "45", "9", "Share", "Locked",
            "Andy Matuschak", "Creating tools for thought", "Become a member"
        ]
        let teaser = """
            A personal note: a long book project has eaten up my weeks, and I've \
            been quite distracted these past few weeks
            """
        var blocks: [AIService.PaperContentBlock] = []
        var removeBlocks: [String] = []
        for (offset, text) in noise.enumerated() {
            let id = String(format: "B%06d", offset + 1)
            blocks.append(AIService.PaperContentBlock(id: id, text: text))
            removeBlocks.append(id)
        }
        // Insert the teaser where the extraction has it, after "Locked".
        blocks.insert(
            AIService.PaperContentBlock(id: "B000999", text: teaser),
            at: 20
        )

        let clean = try PaperContentPreparationService.reconstruct(
            title: "Preparatory notes for a manifesto | Patreon",
            blocks: blocks,
            applying: AIService.PaperContentDeletionPlan(
                removeBlocks: removeBlocks,
                removeText: []
            )
        )

        #expect(clean.hasSuffix(teaser))
        #expect(!clean.contains("Join to unlock"))
        #expect(!clean.contains("Skip navigation"))
    }

    @Test("cleanup does not judge a valid deletion plan by retained character ratio")
    func cleanupHasNoRetainedCharacterRatioHeuristic() throws {
        var blocks: [AIService.PaperContentBlock] = []
        var removeBlocks: [String] = []
        for index in 1...400 {
            let id = String(format: "B%06d", index)
            blocks.append(
                AIService.PaperContentBlock(
                    id: id,
                    text: "Model-classified removable source text in block \(index)."
                )
            )
            removeBlocks.append(id)
        }
        blocks.append(
            AIService.PaperContentBlock(id: "B000401", text: "One retained sentence.")
        )

        let clean = try PaperContentPreparationService.reconstruct(
            title: "A Long Source",
            blocks: blocks,
            applying: AIService.PaperContentDeletionPlan(
                removeBlocks: removeBlocks,
                removeText: []
            )
        )

        #expect(clean == "A Long Source\n\nOne retained sentence.")
    }

    @Test("cleanup deletion units preserve every nonempty extracted line")
    func paperCleanupUsesPhysicalLines() {
        let blocks = PaperContentPreparationService.semanticBlocks(
            "Publisher header\nAging involves a real result.\nThe result continues here.\n\nReferences"
        )
        #expect(blocks.map(\.text) == [
            "Publisher header",
            "Aging involves a real result.",
            "The result continues here.",
            "References"
        ])
    }

    /// Dario Amodei's "The Adolescence of Technology" (2026-10-06): both
    /// prompts listed endnotes as noise, and a cleanup deleted the essay's 46
    /// footnotes of the author's own commentary.
    @Test("cleanup keeps footnotes in the author's words and drops only notes that just cite")
    func cleanupPromptsKeepProseNotes() {
        for prompt in [Prompts.paperNarrationPreparation, Prompts.paperContentDeletionAudit] {
            #expect(prompt.contains("does nothing but cite a source"))
            #expect(!prompt.contains("entries or endnotes"))
            #expect(!prompt.contains(", an endnote,"))
        }
        #expect(Prompts.paperNarrationPreparation.contains("Keep every footnote and endnote written in the author's own words"))
        #expect(Prompts.paperContentDeletionAudit.contains("footnotes and endnotes written in the author's own words"))
    }
}
