#if os(macOS)
import Foundation

// MARK: - How often each tool is called, counted anonymously
//
// The product owner, 2026-11-25, looking at a catalogue of about 400 tools:
// "is it ever tracked somewhere what the usage is of individual mcp tool
// calls? ... can be anonymized". Every finished call adds one to a tally
// keyed by the UTC day, the tool and where the call came from: `in_app`
// (ForeverLM's own chat, Settings and scheduled tasks) or `assistant` (Claude,
// ChatGPT or another AI app). Once a day the finished days go to the gateway
// (`POST plugin.foreverlm.com/telemetry/tool-usage`, foreverlm-private
// `workers/mcp-gateway/src/tool-usage.ts`), which sums them with every other
// Mac's into `tool_usage_daily`.
//
// What leaves the Mac is the tally and the app's version, nothing else: no
// account, installation id, argument, result or library content. The gateway
// does not store the address either. Development builds count nothing, so
// agents exercising tools do not drown out what learners do.

actor MCPToolUsageCounter {
    static let shared = MCPToolUsageCounter()

    static let endpoint = URL(string: "https://plugin.foreverlm.com/telemetry/tool-usage")!

    struct Key: Hashable, Codable {
        let day: String
        let tool: String
        let surface: String
    }

    struct Tally: Codable {
        var calls = 0
        var errors = 0
        var totalMilliseconds = 0
    }

    private struct Stored: Codable {
        var tallies: [Entry] = []
        var lastUploadDay: String?

        struct Entry: Codable {
            let key: Key
            let tally: Tally
        }
    }

    private var tallies: [Key: Tally] = [:]
    private var lastUploadDay: String?
    private var loaded = false
    private var unsavedCalls = 0
    private var uploading = false
    private let fileURL: URL
    private let session: URLSession

    init(
        fileURL: URL = ForeverLMRuntimeIdentity.applicationSupportRootURL
            .appendingPathComponent(".appdata", isDirectory: true)
            .appendingPathComponent("mcp-tool-usage.json"),
        session: URLSession = .shared
    ) {
        self.fileURL = fileURL
        self.session = session
    }

    /// Whether this build reports at all. Development builds and tests do not.
    static var isEnabled: Bool {
        #if FOREVERLM_DEVELOPMENT || DEBUG
        return false
        #else
        return true
        #endif
    }

    /// One finished call. Called off the caller's path, so it never slows a tool.
    nonisolated static func note(tool: String, fromApp: Bool, isError: Bool, milliseconds: Int) {
        guard isEnabled else { return }
        Task.detached(priority: .utility) {
            await shared.record(tool: tool, surface: fromApp ? "in_app" : "assistant", isError: isError, milliseconds: milliseconds)
        }
    }

    func record(tool: String, surface: String, isError: Bool, milliseconds: Int, now: Date = Date()) async {
        loadIfNeeded()
        let key = Key(day: Self.utcDay(now), tool: tool, surface: surface)
        var tally = tallies[key] ?? Tally()
        tally.calls += 1
        if isError { tally.errors += 1 }
        tally.totalMilliseconds += max(0, milliseconds)
        tallies[key] = tally
        unsavedCalls += 1
        // A small file rewritten every 25 calls: a quit loses at most a few counts.
        if unsavedCalls >= 25 { save() }
        await uploadFinishedDaysIfDue(now: now)
    }

    /// The days before today, once per day. A day the gateway refused or could
    /// not be reached stays and goes with the next day's report.
    func uploadFinishedDaysIfDue(now: Date = Date()) async {
        let today = Self.utcDay(now)
        guard !uploading, lastUploadDay != today else { return }
        let finished = tallies.filter { $0.key.day < today }
        guard !finished.isEmpty else { return }
        uploading = true
        defer { uploading = false }
        lastUploadDay = today
        save()
        guard let body = Self.reportBody(finished) else { return }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30
        guard let (_, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        for key in finished.keys { tallies[key] = nil }
        save()
    }

    static func reportBody(_ tallies: [Key: Tally]) -> Data? {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let rows: [[String: Any]] = tallies
            .sorted { ($0.key.day, $0.key.tool, $0.key.surface) < ($1.key.day, $1.key.tool, $1.key.surface) }
            .prefix(2000)
            .map { key, tally in
                [
                    "day": key.day,
                    "tool": key.tool,
                    "surface": key.surface,
                    "calls": tally.calls,
                    "errors": min(tally.errors, tally.calls),
                    "total_ms": tally.totalMilliseconds,
                ]
            }
        return try? JSONSerialization.data(withJSONObject: [
            "app_version": "\(short) (\(build))",
            "platform": "macos",
            "rows": rows,
        ])
    }

    static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        lastUploadDay = stored.lastUploadDay
        for entry in stored.tallies { tallies[entry.key] = entry.tally }
    }

    private func save() {
        unsavedCalls = 0
        let stored = Stored(
            tallies: tallies.map { Stored.Entry(key: $0.key, tally: $0.value) },
            lastUploadDay: lastUploadDay
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
#endif
