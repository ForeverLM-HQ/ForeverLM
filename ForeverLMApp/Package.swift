// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "ForeverLMCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ForeverLMCore", targets: ["ForeverLMCore"]),
        .executable(name: "ForeverLMWebAssembly", targets: ["ForeverLMWebAssembly"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", exact: "0.57.0"),
    ],
    targets: [
        .target(
            name: "ForeverLMCore",
            path: "Shared/Portable",
            // The memory review's portable files are shared by the Mac and the
            // iPhone, but they lean on app models that have not moved here yet
            // (LearningCohort, MemoryTutorModels, SourceIdea, Prompts); the
            // understanding probes lean on the grade and the idea states. The
            // website has no memory review, so the WebAssembly build leaves
            // them out until those models are portable too; the design record's
            // "WASM bridge does not yet export the ladder" is this gap.
            exclude: [
                "DailyReviewPreparationCore.swift",
                "MemoryReviewCandidates.swift",
                "MemoryReviewTutoring.swift",
                "MemoryUnderstandingProbe.swift",
                "SourceIdeaDrafting.swift",
                // The walkthrough step marker is parsed by the Mac chat and
                // stripped on the iPhone; the website plays no walkthrough,
                // and with this file in the bundle the wasm measured 46 MB on
                // 2026-09-20, the ICU size again.
                "WalkthroughStepTurn.swift",
            ]
        ),
        .executableTarget(
            name: "ForeverLMWebAssembly",
            dependencies: [
                "ForeverLMCore",
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ],
            path: "WebAssembly/Sources/ForeverLMWebAssembly"
        ),
        .testTarget(
            name: "ForeverLMCoreTests",
            dependencies: ["ForeverLMCore"],
            path: "WebAssembly/Tests/ForeverLMCoreTests"
        ),
    ]
)
