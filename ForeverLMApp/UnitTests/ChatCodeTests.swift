import Foundation
import Testing
@testable import ForeverLM

/// The chat's code tool: its contract, the sandbox it runs under, and how a
/// run is reported back to the model. Nothing here installs a package or
/// reaches the network.
@Suite("Chat code tool")
struct ChatCodeTests {
    private final class StubRunner: ChatCodeRunner, @unchecked Sendable {
        func run(_ request: ChatCode.Request, sessionKey: String) async -> ChatCode.Outcome { ChatCode.Outcome() }
    }

    // MARK: Offering the tool

    @Test("run_code rides the chat and Deep Research, only with a runner, never a review")
    @MainActor
    func toolIsOfferedWhereTheMacRunsCode() {
        let chat = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false, appTools: [], hasSynthesisContext: false,
            mode: .assistant, codeRunner: StubRunner()
        ).map(\.name)
        #expect(chat.contains(ChatCode.toolName))

        let research = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false, appTools: [], hasSynthesisContext: false,
            mode: .deepResearch, codeRunner: StubRunner()
        ).map(\.name)
        #expect(research.contains(ChatCode.toolName))

        let review = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: true, appTools: [], hasSynthesisContext: false,
            mode: .review, codeRunner: StubRunner()
        ).map(\.name)
        #expect(!review.contains(ChatCode.toolName))

        let withoutRunner = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false, appTools: [], hasSynthesisContext: false, mode: .assistant
        ).map(\.name)
        #expect(!withoutRunner.contains(ChatCode.toolName))
    }

    @Test("The tool's schema is an object that requires code and says where pictures go")
    func specIsWellFormed() {
        let spec = ChatCode.toolSpec()
        #expect(spec.name == "run_code")
        #expect(spec.inputSchema["type"] as? String == "object")
        #expect((spec.inputSchema["required"] as? [String]) == ["code"])
        let properties = spec.inputSchema["properties"] as? [String: Any]
        #expect(properties?["packages"] != nil)
        #expect(properties?["timeout_seconds"] != nil)
        #expect(spec.description.contains("Markdown image line"))
        #expect(spec.description.contains("rdkit"))
    }

    // MARK: Arguments

    @Test("A call needs code, and its limits are kept in range")
    func parsingKeepsLimits() throws {
        #expect(throws: ChatCode.RequestError.missingCode) { try ChatCode.parse([:]) }
        #expect(throws: ChatCode.RequestError.missingCode) { try ChatCode.parse(["code": "  \n "]) }

        let plain = try ChatCode.parse(["code": "print(1)"])
        #expect(plain.timeoutSeconds == ChatCode.defaultTimeoutSeconds)
        #expect(plain.packages.isEmpty)

        let huge = try ChatCode.parse(["code": "print(1)", "timeout_seconds": 9_999])
        #expect(huge.timeoutSeconds == ChatCode.maxTimeoutSeconds)
        let tiny = try ChatCode.parse(["code": "print(1)", "timeout_seconds": 0])
        #expect(tiny.timeoutSeconds == 1)

        let repeated = try ChatCode.parse(["code": "x", "packages": ["rdkit", " rdkit ", "pandas==2.2.0", ""]])
        #expect(repeated.packages == ["rdkit", "pandas==2.2.0"])
    }

    @Test("Only a PyPI name, optionally pinned, is installable")
    func packageNamesAreNarrow() throws {
        for good in ["rdkit", "scikit-learn", "biopython==1.84", "ruamel.yaml", "Pillow", "numpy==2.1.0rc1"] {
            #expect(ChatCode.isInstallablePackage(good), Comment(rawValue: good))
        }
        for bad in [
            "", "-e .", "--index-url", "git+https://example.org/x.git", "https://example.org/x.whl",
            "../local", "/tmp/pkg", "numpy; rm -rf ~", "pkg @ file:///x", "numpy>=1", "numpy==", "a==1==2",
            "pandas --extra-index-url x", String(repeating: "a", count: 90),
        ] {
            #expect(!ChatCode.isInstallablePackage(bad), Comment(rawValue: bad))
        }
        #expect(throws: ChatCode.RequestError.notInstallable("git+https://example.org/x.git")) {
            try ChatCode.parse(["code": "x", "packages": ["git+https://example.org/x.git"]])
        }
        let many = (0...ChatCode.maxPackages).map { "pkg\($0)" }
        #expect(throws: ChatCode.RequestError.tooManyPackages) {
            try ChatCode.parse(["code": "x", "packages": many])
        }
    }

    @Test("The row says what a script does: its description, else its first working line")
    func activityDetail() {
        #expect(ChatCode.activityDetail(arguments: ["code": "x = 1", "description": " Plot decay "]) == "Plot decay")
        #expect(ChatCode.activityDetail(arguments: ["code": "import numpy as np\nfrom math import pi\n# note\nresult = np.mean([1, 2])"]) == "result = np.mean([1, 2])")
        let long = "value = " + String(repeating: "1 + ", count: 40) + "1"
        #expect(ChatCode.activityDetail(arguments: ["code": long])?.hasSuffix("…") == true)
        #expect(ChatCode.activityDetail(arguments: [:]) == nil)
    }

    // MARK: Reporting a run

    private func request() throws -> ChatCode.Request { try ChatCode.parse(["code": "print(1)"]) }

    @Test("A clean run reports its output, its pictures and the other files it left")
    func successfulRun() throws {
        var outcome = ChatCode.Outcome()
        outcome.stdout = "42\n"
        outcome.exitStatus = 0
        outcome.seconds = 1.25
        outcome.files = [
            ChatCode.OutputFile(name: "chart.png", path: "/w/chart.png", byteCount: 5_000),
            ChatCode.OutputFile(name: "data.csv", path: "/w/data.csv", byteCount: 2_048),
        ]
        let result = ChatCode.modelText(for: outcome, request: try request(), pictureLines: ["![Chart](foreverlm://image/generated/abc)"])
        #expect(!result.isError)
        #expect(result.text.contains("Finished in 1.2 s") || result.text.contains("Finished in 1.3 s"))
        #expect(result.text.contains("stdout:\n42"))
        #expect(result.text.contains("![Chart](foreverlm://image/generated/abc)"))
        #expect(result.text.contains("data.csv (2.0 KB)"))
        #expect(!result.text.contains("chart.png ("), "a picture is shown, not listed as a file")
    }

    @Test("A failed, stopped, killed or cancelled run says so and is an error")
    func failuresAreNamed() throws {
        var failed = ChatCode.Outcome()
        failed.exitStatus = 1
        failed.stderr = "ZeroDivisionError: division by zero"
        let failedResult = ChatCode.modelText(for: failed, request: try request(), pictureLines: [])
        #expect(failedResult.isError)
        #expect(failedResult.text.contains("exit status 1"))
        #expect(failedResult.text.contains("ZeroDivisionError"))

        var slow = ChatCode.Outcome()
        slow.timedOut = true
        let slowResult = ChatCode.modelText(for: slow, request: try request(), pictureLines: [])
        #expect(slowResult.isError)
        #expect(slowResult.text.contains("Stopped after \(ChatCode.defaultTimeoutSeconds) s"))

        var killed = ChatCode.Outcome()
        killed.killedBySignal = true
        #expect(ChatCode.modelText(for: killed, request: try request(), pictureLines: []).isError)

        var stopped = ChatCode.Outcome()
        stopped.cancelled = true
        let stoppedResult = ChatCode.modelText(for: stopped, request: try request(), pictureLines: [])
        #expect(stoppedResult.isError)
        #expect(stoppedResult.text.contains("learner stopped"))

        var broken = ChatCode.Outcome()
        broken.setupFailure = "Running code needs Python 3.10 or newer."
        let brokenResult = ChatCode.modelText(for: broken, request: try request(), pictureLines: [])
        #expect(brokenResult.isError)
        #expect(brokenResult.text.hasPrefix("Error: Running code needs Python"))
    }

    @Test("A silent run says it printed nothing instead of leaving the model to invent output")
    func silentRun() throws {
        var outcome = ChatCode.Outcome()
        outcome.exitStatus = 0
        #expect(ChatCode.modelText(for: outcome, request: try request(), pictureLines: []).text.contains("printed nothing"))
    }

    @Test("A long stream keeps its start and its end")
    func truncationKeepsBothEnds() {
        let text = "START" + String(repeating: "x", count: 50_000) + "END"
        let shown = ChatCode.truncated(text)
        #expect(shown.hasPrefix("START"))
        #expect(shown.hasSuffix("END"))
        #expect(shown.contains("characters left out"))
        #expect(shown.count < ChatCode.outputCharacterLimit + 100)
        #expect(ChatCode.truncated("short") == "short")
    }

    // MARK: The sandbox

    @Test("The profile writes to one folder, has no network, and hides the places credentials live")
    func profileShape() {
        let profile = ChatCode.sandboxProfile(workspace: "/w/chat \"a\"", readableSupport: ["/c/venv"], home: "/Users/zara")
        #expect(profile.contains("(deny network*)"))
        #expect(profile.contains("(deny file-write*)"))
        #expect(profile.contains("(allow file-write* (subpath \"/w/chat \\\"a\\\"\")"))
        #expect(profile.contains("(deny file-read* (subpath \"/Users/zara/.ssh\"))"))
        #expect(profile.contains("(deny file-read* (subpath \"/Users/zara/Library/Application Support\"))"))
        // Last match wins, so each allow must come after the deny it narrows.
        let deny = profile.range(of: "/Users/zara/Library/Caches")!.lowerBound
        let allow = profile.range(of: "(allow file-read* (subpath \"/c/venv\"))")!.lowerBound
        #expect(deny < allow)
    }

    private func temporaryRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ChatCodeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs a shell snippet under the real profile, in a workspace of its own.
    private func sandboxed(_ script: String, timeout: TimeInterval = 20) async throws -> (CodeProcess.Result, URL) {
        let root = try temporaryRoot()
        let workspace = CodeProcess.realPath(root.appendingPathComponent("w", isDirectory: true))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let real = CodeProcess.realPath(workspace)
        let profile = ChatCode.sandboxProfile(workspace: real.path, readableSupport: [], home: NSHomeDirectory())
        let result = await CodeProcess.run(
            executable: StudioChatCodeRunner.sandboxExecPath,
            arguments: ["-p", profile, "/bin/sh", "-c", script],
            environment: ["PATH": "/usr/bin:/bin"],
            directory: real.path,
            timeout: timeout
        )
        return (result, real)
    }

    @Test("Under the profile a script writes in its folder and nowhere else")
    func sandboxLimitsWrites() async throws {
        let (inside, workspace) = try await sandboxed("echo ok > made.txt && cat made.txt")
        #expect(inside.status == 0)
        #expect(inside.stdout.contains("ok"))
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("made.txt").path))

        let outside = NSTemporaryDirectory() + "ChatCodeTests-outside-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: outside) }
        let (blocked, _) = try await sandboxed("echo no > '\(outside)'")
        #expect(blocked.status != 0)
        #expect(!FileManager.default.fileExists(atPath: outside))
    }

    @Test("Under the profile a script cannot read the learner's Documents or reach a host")
    func sandboxHidesFilesAndNetwork() async throws {
        let (documents, _) = try await sandboxed("ls '\(NSHomeDirectory())/Documents'")
        #expect(documents.status != 0)
        #expect(documents.stderr.contains("not permitted"))

        let (network, _) = try await sandboxed("/usr/bin/curl -s -m 5 https://example.org")
        #expect(network.status != 0)
    }

    @Test("A script that runs past its limit is stopped, and its output so far is kept")
    func timeoutStopsAScript() async throws {
        let started = Date()
        let (result, _) = try await sandboxed("echo started; sleep 30", timeout: 1)
        #expect(result.timedOut)
        #expect(result.stdout.contains("started"))
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("Cancelling the task that runs a script ends it at once")
    func cancellationStopsAScript() async throws {
        let task = Task { try await sandboxed("sleep 30") }
        try await Task.sleep(nanoseconds: 800_000_000)
        let started = Date()
        task.cancel()
        let (result, _) = try await task.value
        #expect(result.cancelled)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("A chat's folder name cannot climb out of the workspaces folder")
    func workspaceNamesStayInside() throws {
        let root = try temporaryRoot()
        let runner = StudioChatCodeRunner(supportRoot: root.appendingPathComponent("support"), cacheRoot: root.appendingPathComponent("cache"))
        let normal = try runner.workspaceURL(for: "0F3A-77")
        #expect(normal.lastPathComponent == "0F3A-77")
        // The folder exists now, so its real path is the one to compare with.
        let base = CodeProcess.realPath(root.appendingPathComponent("support/Workspaces")).path
        let hostile = try runner.workspaceURL(for: "../../etc/passwd")
        #expect(hostile.path.hasPrefix(base + "/"))
        #expect(!hostile.path.contains(".."))
    }
}
