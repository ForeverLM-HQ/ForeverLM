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

    @Test("The profile starts from nothing and allows back only the system, its Python and its own folder")
    func profileShape() {
        let profile = ChatCode.sandboxProfile(
            workspace: "/w/chat \"a\"",
            runtime: ChatCode.SandboxRuntime(
                readable: ["/c/venv", "/py/cpython-3.12"],
                executables: ["/py/cpython-3.12/bin/python3.12"]
            )
        )
        let lines = profile.components(separatedBy: "\n")
        #expect(lines.prefix(3) == ["(version 1)", "(deny default)", "(import \"system.sb\")"])
        #expect(!profile.contains("(allow default)"))
        #expect(profile.contains("(allow file-read* file-write* (subpath \"/w/chat \\\"a\\\"\"))"))
        #expect(profile.contains("(allow file-read* file-map-executable (subpath \"/c/venv\") (subpath \"/py/cpython-3.12\"))"))
        // One program may start, named exactly: no shell, no `open`, no fork.
        #expect(profile.contains("(allow process-exec (literal \"/py/cpython-3.12/bin/python3.12\"))"))
        #expect(!profile.contains("process-fork"))
        #expect(!profile.contains("process-exec*"))
        #expect(!profile.contains("mach-lookup"))
        // Nothing may write outside the folder, and the network rule comes
        // last, so no earlier allow reaches a socket.
        #expect(lines.filter { $0.contains("file-write") }.count == 1)
        #expect(lines.last == "(deny network*)")
    }

    private func temporaryRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ChatCodeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs a bash snippet under the real profile, in a workspace of its own,
    /// with bash as the one program it may start. The profile allows no fork,
    /// so the snippets use bash's builtins: any other program is refused,
    /// which one test checks.
    private func sandboxed(_ script: String, timeout: TimeInterval = 20) async throws -> (CodeProcess.Result, URL) {
        let root = try temporaryRoot()
        let workspace = CodeProcess.realPath(root.appendingPathComponent("w", isDirectory: true))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let real = CodeProcess.realPath(workspace)
        let profile = ChatCode.sandboxProfile(
            workspace: real.path,
            runtime: ChatCode.SandboxRuntime(readable: [], executables: ["/bin/bash"])
        )
        let result = await CodeProcess.run(
            executable: StudioChatCodeRunner.sandboxExecPath,
            arguments: ["-p", profile, "/bin/bash", "--noprofile", "--norc", "-c", script],
            environment: ["PATH": "/usr/bin:/bin", "HOME": real.path],
            directory: real.path,
            timeout: timeout
        )
        return (result, real)
    }

    /// A file outside the run's folder, as a secret the learner keeps
    /// elsewhere would be.
    private func outsideSecret() throws -> URL {
        let url = CodeProcess.realPath(try temporaryRoot()).appendingPathComponent("secret.env")
        try "TOKEN=hunter2".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("Under the profile a script writes in its folder and nowhere else")
    func sandboxLimitsWrites() async throws {
        let (inside, workspace) = try await sandboxed("echo ok > made.txt && read line < made.txt && echo \"read $line\"")
        #expect(inside.status == 0, Comment(rawValue: inside.stderr))
        #expect(inside.stdout.contains("read ok"))
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("made.txt").path))

        let outside = NSTemporaryDirectory() + "ChatCodeTests-outside-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: outside) }
        let (blocked, _) = try await sandboxed("echo no > '\(outside)'")
        #expect(blocked.status != 0)
        #expect(!FileManager.default.fileExists(atPath: outside))
    }

    @Test("Under the profile a script reads no file outside its folder, wherever it is")
    func sandboxHidesOtherFiles() async throws {
        let secret = try outsideSecret()
        let (read, _) = try await sandboxed("read line < '\(secret.path)'; echo \"got $line\"")
        #expect(!read.stdout.contains("hunter2"))
        #expect(read.stderr.contains("not permitted"))
    }

    @Test("Under the profile a script starts no other program and reaches no host")
    func sandboxRefusesProgramsAndNetwork() async throws {
        // `open` would hand a URL, and whatever the script put in it, to the
        // learner's browser; `true` stands in for it, so a failing sandbox
        // opens nothing.
        let (program, _) = try await sandboxed("/usr/bin/true")
        #expect(program.status == 126)
        #expect(program.stderr.contains("not permitted"))

        let (network, _) = try await sandboxed("exec 3<>/dev/tcp/1.1.1.1/443 && echo CONNECTED")
        #expect(network.status != 0)
        #expect(!network.stdout.contains("CONNECTED"))
    }

    @Test("A script that runs past its limit is stopped, and its output so far is kept")
    func timeoutStopsAScript() async throws {
        let started = Date()
        let (result, _) = try await sandboxed("echo started; while :; do :; done", timeout: 1)
        #expect(result.timedOut)
        #expect(result.stdout.contains("started"))
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("Cancelling the task that runs a script ends it at once")
    func cancellationStopsAScript() async throws {
        let task = Task { try await sandboxed("while :; do :; done") }
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

/// The tool end to end: the real runner, a real Python environment and a real
/// RDKit, the way a chat uses it. A chat asked what changes between guanine and
/// 8-oxoguanine must come back with a drawing of both and the formulas computed,
/// not recalled (product owner, 2026-10-30: the chat "can't run code?? it should!").
///
/// This installs packages, so the first run on a Mac takes about a minute and
/// needs a network; the environment is kept in the temporary folder, so later
/// runs take seconds. It is skipped where no Python can be found or PyPI cannot
/// be reached and no environment is kept yet.
@Suite("Chat code tool, end to end", .serialized, .enabled(if: ChatCodeEndToEnd.canRun))
struct ChatCodeEndToEndTests {
    private static let drawing = """
    from rdkit import Chem
    from rdkit.Chem import Draw, rdMolDescriptors

    pairs = [
        ("guanine", "Nc1nc2[nH]cnc2c(=O)[nH]1"),
        ("8-oxoguanine", "Nc1nc2[nH]c(=O)[nH]c2c(=O)[nH]1"),
    ]
    mols = [Chem.MolFromSmiles(smiles) for _, smiles in pairs]
    for (name, _), mol in zip(pairs, mols):
        print(name, rdMolDescriptors.CalcMolFormula(mol), mol.GetNumHeavyAtoms())
    Draw.MolsToGridImage(mols, molsPerRow=2, subImgSize=(300, 260), legends=[n for n, _ in pairs]).save("guanine_vs_8oxog.png")
    """

    private func runner() throws -> (StudioChatCodeRunner, URL) {
        let support = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ChatCodeEndToEnd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return (StudioChatCodeRunner(supportRoot: support, cacheRoot: ChatCodeEndToEnd.environmentRoot), support)
    }

    @Test("A chat that is asked to draw guanine and 8-oxoguanine gets the formulas and a picture", .timeLimit(.minutes(10)))
    func drawsMolecules() async throws {
        let (runner, support) = try runner()
        defer { try? FileManager.default.removeItem(at: support) }
        let request = try ChatCode.parse(["code": Self.drawing, "packages": ["rdkit"], "timeout_seconds": 120])

        let outcome = await runner.run(request, sessionKey: "guanine")

        #expect(outcome.setupFailure == nil, Comment(rawValue: outcome.setupFailure ?? ""))
        #expect(outcome.exitStatus == 0, Comment(rawValue: outcome.stderr))
        // The numbers come from the computation: one more oxygen, one more heavy atom.
        #expect(outcome.stdout.contains("guanine C5H5N5O 11"))
        #expect(outcome.stdout.contains("8-oxoguanine C5H5N5O2 12"))

        let picture = try #require(outcome.files.first { $0.name == "guanine_vs_8oxog.png" })
        #expect(picture.isPicture)
        #expect(picture.byteCount > 4_000, "a drawn grid, not an empty canvas")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: picture.path))
        #expect(Array(bytes.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "a PNG")

        // What the model reads back tells it to place the picture in the answer.
        let text = ChatCode.modelText(for: outcome, request: request, pictureLines: ["![guanine](foreverlm://image/generated/x)"])
        #expect(!text.isError)
        #expect(text.text.contains("![guanine](foreverlm://image/generated/x)"))
        #expect(text.text.contains("C5H5N5O2"))
    }

    @Test("A later run in the same chat finds the files an earlier one left, and the sandbox still has no network", .timeLimit(.minutes(10)))
    func foldersLastAndNetworkIsClosed() async throws {
        let (runner, support) = try runner()
        defer { try? FileManager.default.removeItem(at: support) }

        let first = try ChatCode.parse(["code": "open('notes.txt', 'w').write('kept')\nprint('written')"])
        let wrote = await runner.run(first, sessionKey: "chat-a")
        #expect(wrote.exitStatus == 0, Comment(rawValue: wrote.stderr))

        let second = try ChatCode.parse(["code": """
        import socket
        print(open('notes.txt').read())
        try:
            socket.create_connection(('example.org', 443), timeout=5)
            print('NETWORK OPEN')
        except OSError:
            print('network closed')
        """])
        let read = await runner.run(second, sessionKey: "chat-a")
        #expect(read.exitStatus == 0, Comment(rawValue: read.stderr))
        #expect(read.stdout.contains("kept"))
        #expect(read.stdout.contains("network closed"))
        #expect(!read.createdEnvironment, "the environment from the first run is reused")

        let elsewhere = try ChatCode.parse(["code": "print(open('notes.txt').read())"])
        let other = await runner.run(elsewhere, sessionKey: "chat-b")
        #expect(other.exitStatus != 0, "another chat has its own folder")
    }

    @Test("The real environment's script reads no file outside its folder and starts no program", .timeLimit(.minutes(10)))
    func sandboxHoldsForPython() async throws {
        let (runner, support) = try runner()
        defer { try? FileManager.default.removeItem(at: support) }
        let secret = support.appendingPathComponent("secret.env")
        try "TOKEN=hunter2".write(to: secret, atomically: true, encoding: .utf8)
        let probe = try ChatCode.parse(["code": """
        import os, subprocess, numpy, matplotlib.pyplot as plt
        def attempt(label, action):
            try:
                action()
                print(label, "OPEN")
            except OSError:
                print(label, "closed")
        attempt("secret", lambda: open(\(String(reflecting: CodeProcess.realPath(secret).path))).read())
        attempt("home", lambda: os.listdir(os.path.expanduser("~\(NSUserName())")))
        attempt("program", lambda: subprocess.run(["/usr/bin/true"]))
        attempt("python", lambda: subprocess.run([os.sys.executable, "-c", "pass"]))
        plt.plot(numpy.arange(3)); plt.savefig("ok.png")
        print("drew", os.path.exists("ok.png"))
        """])
        let outcome = await runner.run(probe, sessionKey: "escape")
        #expect(outcome.setupFailure == nil, Comment(rawValue: outcome.setupFailure ?? ""))
        #expect(outcome.exitStatus == 0, Comment(rawValue: outcome.stderr))
        for label in ["secret", "home", "program", "python"] {
            #expect(outcome.stdout.contains("\(label) closed"), Comment(rawValue: outcome.stdout))
        }
        #expect(outcome.stdout.contains("drew True"))
    }
}

/// Whether the end-to-end suite can run here, and where its environment is kept.
enum ChatCodeEndToEnd {
    /// Kept across test runs, so only the first one installs anything.
    static let environmentRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("ForeverLMChatCodeEndToEnd", isDirectory: true)

    static let canRun: Bool = {
        guard FileManager.default.isExecutableFile(atPath: StudioChatCodeRunner.sandboxExecPath) else { return false }
        guard CodeEnvironment.locateUV() != nil || hasModernPython else { return false }
        let kept = environmentRoot.appendingPathComponent("venv-\(ChatCode.pythonVersion)/bin/python").path
        if FileManager.default.isExecutableFile(atPath: kept) { return true }
        return pypiIsReachable()
    }()

    /// A Python 3.10 or later in the places the runner looks when there is no uv.
    private static var hasModernPython: Bool {
        ["/opt/homebrew/bin", "/usr/local/bin"].contains { folder in
            ["python3.13", "python3.12", "python3.11", "python3.10"].contains {
                FileManager.default.isExecutableFile(atPath: "\(folder)/\($0)")
            }
        }
    }

    private static func pypiIsReachable() -> Bool {
        var request = URLRequest(url: URL(string: "https://pypi.org/simple/")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 8)
        return reachable
    }
}
