#if os(macOS)
import Foundation
import OSLog

/// Runs the Python a chat's `run_code` tool asks for (`ChatCode`).
///
/// Three things are kept apart. The *environment* is one Python virtual
/// environment shared by every chat, built on first use with the baseline
/// scientific packages and grown by `packages` requests; it lives in Caches,
/// because it can always be made again. A chat's *workspace* is the folder its
/// scripts run in, which lasts as long as the chat, in Application Support.
/// A *run* is one script in a `sandbox-exec` profile (`ChatCode.sandboxProfile`)
/// that starts from deny-all, reads only the system, its Python and the
/// workspace, writes only to the workspace, starts no other program and has
/// no network: installing happens
/// before the run, outside the sandbox, from binary wheels only, so no package
/// executes a build script on the learner's Mac.
///
/// There is no unsandboxed route: a Mac without `sandbox-exec` runs nothing and
/// says so.
final class StudioChatCodeRunner: ChatCodeRunner, @unchecked Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ChatCode")
    static let sandboxExecPath = "/usr/bin/sandbox-exec"

    private let supportRoot: URL
    private let environment: CodeEnvironment

    /// `supportRoot` holds the chats' workspaces and `cacheRoot` the
    /// environment; both are injectable so a test never touches the real ones.
    init(supportRoot: URL? = nil, cacheRoot: URL? = nil) {
        let bundle = Bundle.main.bundleIdentifier ?? "ForeverLM"
        let fm = FileManager.default
        let support = supportRoot ?? (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("CodeRunner", isDirectory: true)
        let cache = cacheRoot ?? (fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches"))
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("CodeRunner", isDirectory: true)
        self.supportRoot = support
        self.environment = CodeEnvironment(root: cache)
    }

    func run(_ request: ChatCode.Request, sessionKey: String) async -> ChatCode.Outcome {
        var outcome = ChatCode.Outcome()
        guard FileManager.default.isExecutableFile(atPath: Self.sandboxExecPath) else {
            outcome.setupFailure = "This Mac has no \(Self.sandboxExecPath), which keeps a script from touching anything but its own folder, so no code was run. ForeverLM does not run code outside that sandbox."
            return outcome
        }
        let workspace: URL
        do {
            workspace = try workspaceURL(for: sessionKey)
        } catch {
            outcome.setupFailure = "Could not make the chat's working folder: \(error.localizedDescription)"
            return outcome
        }
        let prepared = await environment.prepare(packages: request.packages)
        switch prepared {
        case .failure(let failure):
            outcome.setupFailure = failure.message
            return outcome
        case .success(let ready):
            outcome.createdEnvironment = ready.created
            outcome.installedPackages = ready.installed
            return await execute(request, in: workspace, using: ready, outcome: outcome)
        }
    }

    // MARK: - Running a script

    private func execute(_ request: ChatCode.Request, in workspace: URL, using ready: CodeEnvironment.Ready, outcome start: ChatCode.Outcome) async -> ChatCode.Outcome {
        var outcome = start
        let fm = FileManager.default
        let scriptDirectory = workspace.appendingPathComponent(".run", isDirectory: true)
        let temporary = workspace.appendingPathComponent(".tmp", isDirectory: true)
        let matplotlib = workspace.appendingPathComponent(".mplconfig", isDirectory: true)
        let script = scriptDirectory.appendingPathComponent("script.py")
        do {
            for directory in [scriptDirectory, temporary, matplotlib] {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try request.code.write(to: script, atomically: true, encoding: .utf8)
        } catch {
            outcome.setupFailure = "Could not write the script: \(error.localizedDescription)"
            return outcome
        }
        let before = Self.snapshot(of: workspace)
        let profile = ChatCode.sandboxProfile(workspace: workspace.path, runtime: ready.runtime)
        let venvBin = ready.python.deletingLastPathComponent().path
        let environment = [
            "PATH": "\(venvBin):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": workspace.path,
            "TMPDIR": temporary.path,
            "MPLBACKEND": "Agg",
            "MPLCONFIGDIR": matplotlib.path,
            "VIRTUAL_ENV": ready.environmentRoot.path,
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONIOENCODING": "utf-8",
            "PYTHONUTF8": "1",
            "LANG": "en_US.UTF-8",
        ]
        let started = Date()
        let result = await CodeProcess.run(
            executable: Self.sandboxExecPath,
            arguments: ["-p", profile, ready.python.path, "-u", script.path],
            environment: environment,
            directory: workspace.path,
            timeout: TimeInterval(request.timeoutSeconds)
        )
        outcome.seconds = Date().timeIntervalSince(started)
        outcome.stdout = result.stdout
        outcome.stderr = result.stderr
        outcome.timedOut = result.timedOut
        outcome.cancelled = result.cancelled
        outcome.killedBySignal = result.status == nil && !result.timedOut && !result.cancelled && result.launchError == nil
        outcome.exitStatus = result.status
        if let launchError = result.launchError {
            outcome.setupFailure = "Could not start Python: \(launchError)"
        }
        outcome.files = Self.changedFiles(in: workspace, since: before)
        return outcome
    }

    // MARK: - Workspaces

    /// The folder a chat's scripts run in. The key is a chat's id, kept to
    /// characters that cannot climb out of the folder.
    func workspaceURL(for sessionKey: String) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let safe = String(sessionKey.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        guard !safe.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let url = supportRoot
            .appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return CodeProcess.realPath(url)
    }

    private struct FileStamp: Equatable {
        let size: Int
        let modified: Date
    }

    private static func snapshot(of folder: URL) -> [String: FileStamp] {
        var stamps: [String: FileStamp] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return stamps }
        let base = CodeProcess.realPath(folder).path + "/"
        for case let url as URL in walker {
            guard stamps.count < 5_000,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let path = CodeProcess.realPath(url).path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
            stamps[relative] = FileStamp(size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
        }
        return stamps
    }

    private static func changedFiles(in folder: URL, since before: [String: FileStamp]) -> [ChatCode.OutputFile] {
        let after = snapshot(of: folder)
        return after
            .filter { before[$0.key] != $0.value }
            .sorted { $0.value.modified == $1.value.modified ? $0.key < $1.key : $0.value.modified < $1.value.modified }
            .prefix(50)
            .map { ChatCode.OutputFile(name: $0.key, path: folder.appendingPathComponent($0.key).path, byteCount: $0.value.size) }
    }
}

// MARK: - The Python environment

/// The one virtual environment every chat shares. An actor, so two chats that
/// both need an install take turns instead of writing to it at once.
actor CodeEnvironment {
    struct Ready {
        let python: URL
        let environmentRoot: URL
        /// What the run's sandbox lets it read and start (`ChatCode.SandboxRuntime`).
        let runtime: ChatCode.SandboxRuntime
        let created: Bool
        let installed: [String]
    }

    struct Failure: Error {
        let message: String
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ChatCode")
    private let root: URL
    /// The sandbox's view of the environment, asked of its Python once and
    /// kept until the environment is made again.
    private var runtime: ChatCode.SandboxRuntime?
    private var venv: URL { root.appendingPathComponent("venv-\(ChatCode.pythonVersion)", isDirectory: true) }
    private var venvPython: URL { venv.appendingPathComponent("bin/python") }

    /// A first install downloads the scientific stack; a package with no wheel
    /// for this Mac fails fast, so the limit is for a slow connection.
    private static let installTimeout: TimeInterval = 900

    init(root: URL) {
        self.root = root
    }

    func prepare(packages: [String]) async -> Result<Ready, Failure> {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return .failure(Failure(message: "Could not make the code environment's folder: \(error.localizedDescription)"))
        }
        var created = false
        if !fm.isExecutableFile(atPath: venvPython.path) {
            if let failure = await createEnvironment() { return .failure(failure) }
            created = true
        }
        var installed: [String] = []
        let missing = await missingPackages(among: packages)
        if !missing.isEmpty {
            if let failure = await install(missing) { return .failure(failure) }
            installed = missing
        }
        let runtime: ChatCode.SandboxRuntime
        switch await sandboxRuntime() {
        case .failure(let failure): return .failure(failure)
        case .success(let found): runtime = found
        }
        return .success(Ready(
            python: venvPython,
            environmentRoot: CodeProcess.realPath(venv),
            runtime: runtime,
            created: created,
            installed: installed
        ))
    }

    /// What a run needs from outside its folder: the environment, the Python
    /// installation it was made from, and the interpreter binaries. The
    /// installation is the environment's own answer (`sys.base_prefix`), so a
    /// uv-managed, Homebrew or python.org Python each name their real place.
    /// The sandbox checks the real path of a program it starts, so the
    /// interpreter is named through its links; a framework build's
    /// `bin/python3.x` is a launcher that hands over to `Python.app`, which is
    /// named too. A Python that cannot say where it lives runs nothing.
    private func sandboxRuntime() async -> Result<ChatCode.SandboxRuntime, Failure> {
        if let runtime { return .success(runtime) }
        let probe = await CodeProcess.run(
            executable: venvPython.path,
            arguments: ["-I", "-c", "import os, sys; print(os.path.realpath(sys.base_prefix))"],
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
            directory: root.path,
            timeout: 30
        )
        let installation = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard probe.status == 0, installation.hasPrefix("/"), installation != "/" else {
            return .failure(Failure(message: "Could not ask the code environment's Python where it is installed, so no code was run: \(Self.tail(probe.stderr.isEmpty ? probe.stdout : probe.stderr))"))
        }
        var executables = [CodeProcess.realPath(venvPython).path]
        let launcherTarget = installation + "/Resources/Python.app/Contents/MacOS/Python"
        if FileManager.default.isExecutableFile(atPath: launcherTarget) {
            executables.append(CodeProcess.realPath(URL(fileURLWithPath: launcherTarget)).path)
        }
        let found = ChatCode.SandboxRuntime(
            readable: [CodeProcess.realPath(venv).path, installation],
            executables: executables
        )
        runtime = found
        return .success(found)
    }

    // MARK: Creating

    private func createEnvironment() async -> Failure? {
        let fm = FileManager.default
        // A half-made environment from an earlier failure is made again.
        try? fm.removeItem(at: venv)
        runtime = nil
        if let uv = Self.locateUV() {
            let made = await CodeProcess.run(
                executable: uv.path,
                arguments: ["venv", venv.path, "--python", ChatCode.pythonVersion, "--seed"],
                environment: installEnvironment(),
                directory: root.path,
                timeout: Self.installTimeout
            )
            guard made.status == 0 else {
                return Failure(message: "Could not create the Python environment with uv: \(Self.tail(made.stderr.isEmpty ? made.stdout : made.stderr))")
            }
        } else if let python = await Self.locatePython() {
            let made = await CodeProcess.run(
                executable: python.path,
                arguments: ["-m", "venv", venv.path],
                environment: installEnvironment(),
                directory: root.path,
                timeout: 120
            )
            guard made.status == 0 else {
                return Failure(message: "Could not create the Python environment: \(Self.tail(made.stderr.isEmpty ? made.stdout : made.stderr))")
            }
        } else {
            return Failure(message: "Running code needs Python 3.10 or newer, and this Mac has neither uv nor such a Python. Install one (for example `brew install uv`), then ask again.")
        }
        if let failure = await install(ChatCode.baselinePackages) {
            try? fm.removeItem(at: venv)
            return failure
        }
        return nil
    }

    // MARK: Installing

    /// Which of the requested packages the environment does not hold, so a
    /// package asked for in every call is installed once.
    private func missingPackages(among packages: [String]) async -> [String] {
        guard !packages.isEmpty else { return [] }
        let check = """
        import importlib.metadata as m, json, sys
        missing = []
        for spec in json.loads(sys.argv[1]):
            name, _, pin = spec.partition("==")
            try:
                if pin and m.version(name) != pin:
                    missing.append(spec)
                else:
                    m.version(name)
            except m.PackageNotFoundError:
                missing.append(spec)
        print(json.dumps(missing))
        """
        let encoded = (try? JSONSerialization.data(withJSONObject: packages)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let result = await CodeProcess.run(
            executable: venvPython.path,
            arguments: ["-c", check, encoded],
            environment: installEnvironment(),
            directory: root.path,
            timeout: 30
        )
        guard result.status == 0,
              let data = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let names = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            // The check failing must not skip an install the script needs.
            return packages
        }
        return names
    }

    private func install(_ packages: [String]) async -> Failure? {
        // Wheels only: a source package would run its build script, unsandboxed.
        let result: CodeProcess.Result
        if let uv = Self.locateUV() {
            result = await CodeProcess.run(
                executable: uv.path,
                arguments: ["pip", "install", "--python", venvPython.path, "--only-binary", ":all:"] + packages,
                environment: installEnvironment(),
                directory: root.path,
                timeout: Self.installTimeout
            )
        } else {
            result = await CodeProcess.run(
                executable: venvPython.path,
                arguments: ["-m", "pip", "install", "--only-binary", ":all:", "--disable-pip-version-check"] + packages,
                environment: installEnvironment(),
                directory: root.path,
                timeout: Self.installTimeout
            )
        }
        if result.status == 0 { return nil }
        Self.logger.error("Installing \(packages.joined(separator: ", "), privacy: .public) failed")
        let reason = result.timedOut
            ? "the install did not finish in \(Int(Self.installTimeout / 60)) minutes"
            : Self.tail(result.stderr.isEmpty ? result.stdout : result.stderr)
        return Failure(message: "Could not install \(packages.joined(separator: ", ")): \(reason) Only binary wheels are installed, so a package that ships none for this Mac cannot be used; try another package or another way.")
    }

    private func installEnvironment() -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "UV_CACHE_DIR": root.appendingPathComponent("uv-cache", isDirectory: true).path,
            "VIRTUAL_ENV": venv.path,
            "LANG": "en_US.UTF-8",
        ]
    }

    // MARK: Finding tools

    /// uv builds the environment on a Python it manages, so a Mac with no
    /// suitable Python still works. The app is launched from the Dock with a
    /// short PATH, so the usual install places are named.
    static func locateUV() -> URL? {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.cargo/bin/uv"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// The newest Python 3.10 or later in the usual places. The Python that
    /// ships with Xcode's tools is 3.9, which the scientific wheels have left.
    static func locatePython() async -> URL? {
        let names = ["python3.13", "python3.12", "python3.11", "python3.10", "python3"]
        let folders = ["/opt/homebrew/bin", "/usr/local/bin", "/Library/Frameworks/Python.framework/Versions/Current/bin"]
        for folder in folders {
            for name in names {
                let path = "\(folder)/\(name)"
                guard FileManager.default.isExecutableFile(atPath: path) else { continue }
                let result = await CodeProcess.run(
                    executable: path,
                    arguments: ["-c", "import sys; print(sys.version_info >= (3, 10))"],
                    environment: ["PATH": "/usr/bin:/bin"],
                    directory: nil,
                    timeout: 15
                )
                if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "True" {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }

    private static func tail(_ text: String, limit: Int = 1_200) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…" + String(trimmed.suffix(limit))
    }
}

// MARK: - Running a process

/// One child process, run to its end, its timeout, or the cancellation of the
/// task that started it.
enum CodeProcess {
    struct Result: Sendable {
        var stdout = ""
        var stderr = ""
        var status: Int32? = nil
        var timedOut = false
        var cancelled = false
        var launchError: String? = nil
    }

    /// Bytes beyond the limit are dropped: a script that prints in a loop must
    /// not fill the Mac's memory before its timeout.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int
        init(limit: Int) { self.limit = limit }

        func append(_ more: Data) {
            lock.lock(); defer { lock.unlock() }
            guard data.count < limit else { return }
            data.append(more.prefix(limit - data.count))
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private(set) var cancelled = false
        private(set) var timedOut = false

        /// False when the task was cancelled before the process could start.
        func start(_ process: Process) throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { return false }
            try process.run()
            self.process = process
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            Self.stop(running)
        }

        func timeOut() {
            lock.lock()
            let running = process
            if running?.isRunning == true { timedOut = true }
            lock.unlock()
            Self.stop(running)
        }

        private static func stop(_ process: Process?) {
            guard let process, process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: String?,
        timeout: TimeInterval,
        captureLimit: Int = 400_000
    ) async -> Result {
        let handle = Handle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
                process.standardInput = FileHandle.nullDevice
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                let out = Capture(limit: captureLimit)
                let err = Capture(limit: captureLimit)
                for (pipe, capture) in [(outPipe, out), (errPipe, err)] {
                    pipe.fileHandleForReading.readabilityHandler = { reading in
                        let data = reading.availableData
                        if data.isEmpty { reading.readabilityHandler = nil } else { capture.append(data) }
                    }
                }
                process.terminationHandler = { finished in
                    // Let the readers take what the pipes still hold, then
                    // read the rest without waiting on a grandchild that
                    // kept a pipe open.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        for (pipe, capture) in [(outPipe, out), (errPipe, err)] {
                            pipe.fileHandleForReading.readabilityHandler = nil
                            drain(pipe.fileHandleForReading, into: capture)
                        }
                        let signalled = finished.terminationReason == .uncaughtSignal
                        continuation.resume(returning: Result(
                            stdout: out.text,
                            stderr: err.text,
                            status: signalled ? nil : finished.terminationStatus,
                            timedOut: handle.timedOut,
                            cancelled: handle.cancelled
                        ))
                    }
                }
                do {
                    guard try handle.start(process) else {
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        process.terminationHandler = nil
                        continuation.resume(returning: Result(cancelled: true))
                        return
                    }
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    continuation.resume(returning: Result(launchError: error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { handle.timeOut() }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// The path with every symlink resolved, `/private` included. The sandbox
    /// matches the real path, and `URL.resolvingSymlinksInPath` drops
    /// `/private` from `/tmp`, `/var` and `/etc`, which names a path the
    /// sandbox never sees.
    static func realPath(_ url: URL) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    /// Reads what a pipe holds right now, without blocking on a writer that
    /// is still open.
    private static func drain(_ reading: FileHandle, into capture: Capture) {
        let descriptor = reading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            capture.append(Data(buffer.prefix(count)))
        }
    }
}
#endif
