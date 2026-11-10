import Foundation

/// The chat's use of code: the `run_code` tool a model calls to run Python on
/// the learner's Mac, and the contract the Mac fulfils behind it.
///
/// A chat that cannot run code answers arithmetic, chemistry, statistics and
/// plots from memory, and the answers are wrong often enough to matter
/// (product owner, 2026-10-30: "ForeverLM chats should be just as flexible as
/// claude and/or chatgpt" at running code). The tool is a real Python with the
/// scientific stack and any wheel on PyPI, a working folder that lasts the
/// chat, and pictures a script saves coming back into the answer. Everything
/// that starts a process lives in the App layer (`StudioChatCodeRunner`); this
/// file is the platform-free part — the tool definition, the argument parsing,
/// the sandbox profile and the wording of results — so the contract is
/// testable without running anything.
enum ChatCode {
    static let toolName = "run_code"

    /// Seconds a script may run when the call names no limit, and the most it
    /// may ask for. A stopped script reports that it was stopped.
    static let defaultTimeoutSeconds = 60
    static let maxTimeoutSeconds = 300

    /// Characters of one output stream a result carries. A longer stream keeps
    /// its start and its end: the start says what ran, the end says how it
    /// finished.
    static let outputCharacterLimit = 12_000

    /// Packages one call may ask for.
    static let maxPackages = 12

    /// The Python the environment is built on. Recent enough that the
    /// scientific wheels (NumPy, SciPy, RDKit, pandas) all ship for it.
    static let pythonVersion = "3.12"

    /// What every environment starts with, so the first plot or table needs no
    /// install step: the stack a learner expects from ChatGPT's code tool.
    static let baselinePackages = ["numpy", "pandas", "matplotlib", "scipy", "sympy"]

    /// Pictures one run may hand back, and the largest each may be.
    static let maxImagesPerRun = 8
    static let maxImageBytes = 20 * 1_048_576

    static let activityTitle = "Ran code"

    // MARK: - Tool

    static func toolSpec() -> AIToolSpec {
        AIToolSpec(
            name: toolName,
            description: """
            Run Python code on the learner's Mac and get its output. Use it whenever an answer depends on computing something rather than recalling it: arithmetic and statistics, unit conversions, parsing or reshaping data, simulations, plots and charts, and chemistry or biology work (RDKit draws molecules, Biopython reads sequences). Do not guess a number you can compute. The scientific stack is installed (numpy, pandas, matplotlib, scipy, sympy); name any other package from PyPI in `packages` and it is installed before the script runs (binary wheels only), for example rdkit, biopython, scikit-learn, seaborn, networkx or pillow.

            The script runs fresh each call, in a folder that belongs to this chat: files it writes there are still there on the next call, but variables are not, so write what a later call needs to a file. Print what you want back; stdout and stderr return to you. The script cannot reach the network or the learner's other files, and cannot start other programs or processes (no subprocess, no multiprocessing), so pass it data inside the code or write it to the working folder first. To show a picture, save it as PNG, JPEG, GIF or WebP in the working folder (matplotlib: plt.savefig("chart.png", dpi=150, bbox_inches="tight"); RDKit: img.save("molecules.png")): each new picture comes back as a Markdown image line. Include every such line verbatim, on its own line, where the picture belongs in your answer, and the learner sees it there. Other files the script writes (CSV, text, PDF) are listed by name with their size.

            When a run fails, read the error and fix the code; do not report a failure you have not tried to fix. When it prints nothing, say so rather than inventing output. Report results from what the run printed, not from what you expected.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "code": [
                        "type": "string",
                        "description": "The Python 3 script to run, complete and self-contained: imports included, nothing read from input().",
                    ],
                    "packages": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "PyPI packages to install first, as a name or name==version, for example [\"rdkit\", \"scikit-learn\"]. Leave out the preinstalled ones.",
                    ] as [String: Any],
                    "timeout_seconds": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": maxTimeoutSeconds,
                        "description": "Seconds the script may run before it is stopped (default \(defaultTimeoutSeconds), at most \(maxTimeoutSeconds)). Installing packages is not counted.",
                    ],
                    "description": [
                        "type": "string",
                        "description": "Five words or fewer saying what the script does, shown to the learner on the step's row.",
                    ],
                ] as [String: Any],
                "required": ["code"],
            ]
        )
    }

    // MARK: - Arguments

    struct Request: Equatable, Sendable {
        var code: String
        var packages: [String]
        var timeoutSeconds: Int
        var summary: String?
    }

    enum RequestError: Error, LocalizedError, Equatable {
        case missingCode
        case notInstallable(String)
        case tooManyPackages

        var errorDescription: String? {
            switch self {
            case .missingCode:
                return "run_code needs code: the complete Python script to run."
            case .notInstallable(let name):
                return "\"\(name)\" is not a package name run_code installs. Pass a PyPI name, optionally pinned as name==version; flags, URLs and file paths are refused."
            case .tooManyPackages:
                return "run_code installs at most \(ChatCode.maxPackages) packages in one call."
            }
        }
    }

    static func parse(_ arguments: [String: Any]) throws -> Request {
        guard let code = (arguments["code"] as? String), !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RequestError.missingCode
        }
        var packages: [String] = []
        for raw in (arguments["packages"] as? [Any] ?? []) {
            guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            guard isInstallablePackage(text) else { throw RequestError.notInstallable(text) }
            if !packages.contains(text) { packages.append(text) }
        }
        guard packages.count <= maxPackages else { throw RequestError.tooManyPackages }
        let asked = (arguments["timeout_seconds"] as? NSNumber)?.intValue
        let timeout = min(max(asked ?? defaultTimeoutSeconds, 1), maxTimeoutSeconds)
        let summary = (arguments["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Request(
            code: code,
            packages: packages,
            timeoutSeconds: timeout,
            summary: (summary?.isEmpty ?? true) ? nil : summary
        )
    }

    /// A PyPI name with an optional exact pin. Anything else — a flag, a URL,
    /// a path, a VCS reference, an extra index — would let a model install
    /// code from somewhere the learner never saw, so it is refused.
    static func isInstallablePackage(_ spec: String) -> Bool {
        guard spec.count <= 80 else { return false }
        let parts = spec.components(separatedBy: "==")
        guard parts.count <= 2, let name = parts.first else { return false }
        let nameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard let first = name.unicodeScalars.first, CharacterSet.alphanumerics.contains(first),
              name.unicodeScalars.allSatisfy({ nameCharacters.contains($0) }) else { return false }
        if parts.count == 2 {
            let versionCharacters = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyz.+!-_")
            let version = parts[1]
            guard !version.isEmpty, version.unicodeScalars.allSatisfy({ versionCharacters.contains($0) }) else { return false }
        }
        return true
    }

    /// The activity row's caption: the call's own description, else the
    /// script's first meaningful line.
    static func activityDetail(arguments: [String: Any]) -> String? {
        if let summary = (arguments["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        guard let code = arguments["code"] as? String else { return nil }
        let line = code
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("import ") && !$0.hasPrefix("from ") }
            ?? code.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line, !line.isEmpty else { return nil }
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    // MARK: - Sandbox

    /// What a run may load and start besides the system: the Python it runs
    /// on, found by `StudioChatCodeRunner` from the environment it built.
    struct SandboxRuntime: Equatable, Sendable {
        /// Folders the run may read and map code from: the virtual
        /// environment (its packages) and the Python installation it was made
        /// from (`sys.base_prefix`: the standard library and its libraries).
        var readable: [String]
        /// The only programs the run may start, by real path: the interpreter
        /// itself, and for a framework build the `Python.app` its
        /// `bin/python3.x` launcher hands over to. Nothing else — no shell, no
        /// `open`, no second Python started by the script.
        var executables: [String]
    }

    /// The macOS sandbox profile a script runs under. A model's code is code
    /// nobody reviewed, run on the learner's Mac, and what it prints goes to a
    /// model provider, so the profile starts from nothing: everything is
    /// denied, and allowed back is only what the system's own base profile
    /// gives every process (`system.sb`: the system's libraries, frameworks
    /// and a curated set of system services, none of which open a URL or an
    /// app), reading the Python it runs on, starting that Python and nothing
    /// else, and reading and writing its own folder. No network, no other
    /// process: an allow-all profile with a list of hidden folders let a
    /// script read any secret it could name and hand a URL to `/usr/bin/open`.
    static func sandboxProfile(workspace: String, runtime: SandboxRuntime) -> String {
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var lines = [
            "(version 1)",
            "(deny default)",
            "(import \"system.sb\")",
        ]
        if !runtime.readable.isEmpty {
            let paths = runtime.readable.map { "(subpath \(quoted($0)))" }.joined(separator: " ")
            lines.append("(allow file-read* file-map-executable \(paths))")
        }
        lines.append("(allow file-read* file-write* (subpath \(quoted(workspace))))")
        if !runtime.executables.isEmpty {
            let paths = runtime.executables.map { "(literal \(quoted($0)))" }.joined(separator: " ")
            lines.append("(allow process-exec \(paths))")
        }
        lines.append("(allow signal (target self))")
        // Last, so nothing the base profile allows reaches a socket.
        lines.append("(deny network*)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Results

    /// A file a run left in the working folder: new, or changed since before
    /// the run.
    struct OutputFile: Equatable, Sendable {
        /// Path relative to the working folder.
        let name: String
        let path: String
        let byteCount: Int

        var isPicture: Bool {
            ["png", "jpg", "jpeg", "gif", "webp"].contains((name as NSString).pathExtension.lowercased())
        }
    }

    struct Outcome: Equatable, Sendable {
        /// Why the run never started: no Python, a failed install, no sandbox.
        var setupFailure: String? = nil
        var stdout = ""
        var stderr = ""
        var exitStatus: Int32? = nil
        var timedOut = false
        /// The chat's Stop ended the run.
        var cancelled = false
        /// The system ended the run with a signal: a crash, or the Mac ran
        /// out of memory.
        var killedBySignal = false
        var seconds: Double = 0
        var installedPackages: [String] = []
        var createdEnvironment = false
        var files: [OutputFile] = []
    }

    /// What the model reads after a run. `pictureLines` are the Markdown lines
    /// for the pictures already stored; a picture that could not be stored is
    /// named in `unstored`.
    static func modelText(for outcome: Outcome, request: Request, pictureLines: [String], unstored: [String] = []) -> (text: String, isError: Bool) {
        if let failure = outcome.setupFailure {
            return ("Error: \(failure)", true)
        }
        var parts: [String] = []
        var failed = false
        if outcome.createdEnvironment {
            parts.append("Set up the Python environment first (\(baselinePackages.joined(separator: ", "))); it is kept for later runs.")
        }
        if !outcome.installedPackages.isEmpty {
            parts.append("Installed: \(outcome.installedPackages.joined(separator: ", ")).")
        }
        let timing = String(format: "%.1f s", outcome.seconds)
        if outcome.cancelled {
            failed = true
            parts.append("The learner stopped the run before it finished.")
        } else if outcome.timedOut {
            failed = true
            parts.append("Stopped after \(request.timeoutSeconds) s: the script was still running. Make it faster or raise timeout_seconds (at most \(maxTimeoutSeconds)). Files it had written are kept.")
        } else if outcome.killedBySignal {
            failed = true
            parts.append("The system ended the script after \(timing), without an error of its own: it crashed or used more memory than the Mac could give it.")
        } else if let status = outcome.exitStatus, status != 0 {
            failed = true
            parts.append("The script failed with exit status \(status) after \(timing).")
        } else {
            parts.append("Finished in \(timing).")
        }
        let out = truncated(outcome.stdout)
        let err = truncated(outcome.stderr)
        if !out.isEmpty { parts.append("stdout:\n\(out)") }
        if !err.isEmpty { parts.append("stderr:\n\(err)") }
        if out.isEmpty, err.isEmpty, !failed {
            parts.append("The script printed nothing.")
        }
        if !pictureLines.isEmpty {
            parts.append("Pictures the script saved (include each line verbatim, on its own line, where the picture belongs in your answer):\n" + pictureLines.joined(separator: "\n"))
        }
        if !unstored.isEmpty {
            parts.append("Not shown, because they could not be stored: " + unstored.joined(separator: "; ") + ".")
        }
        let others = outcome.files.filter { !$0.isPicture }
        if !others.isEmpty {
            let list = others.prefix(20).map { "\($0.name) (\(byteDescription($0.byteCount)))" }.joined(separator: ", ")
            parts.append("Other files in the working folder, still there on the next run: \(list).")
        }
        return (parts.joined(separator: "\n\n"), failed)
    }

    /// The start and the end of a long stream, with what was left out named.
    static func truncated(_ text: String, limit: Int = outputCharacterLimit) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let head = limit * 6 / 10
        let tail = limit - head
        let omitted = trimmed.count - head - tail
        return String(trimmed.prefix(head)) + "\n[… \(omitted) characters left out …]\n" + String(trimmed.suffix(tail))
    }

    static func byteDescription(_ bytes: Int) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1_024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

/// Runs the Python a chat asks for. Implemented on the Mac by
/// `StudioChatCodeRunner`; absent where a process cannot be started (the
/// iPhone, the web), in which case the chat offers no code tool.
protocol ChatCodeRunner: AnyObject, Sendable {
    /// Runs one script for the chat named by `sessionKey`, in that chat's
    /// working folder. Never throws: a run that could not start says why in
    /// `Outcome.setupFailure`.
    func run(_ request: ChatCode.Request, sessionKey: String) async -> ChatCode.Outcome
}
