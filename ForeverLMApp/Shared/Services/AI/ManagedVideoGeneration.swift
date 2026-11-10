import Foundation
import OSLog

/// One finished clip: its bytes, and what the proxy said it cost.
struct GeneratedVideoClip: Sendable {
    let data: Data
    let durationSeconds: Int
    /// The exact debit the proxy recorded, from the code-owned per-second card.
    let costUSD: Double?
    let requestID: String?
}

/// One text-to-video request through OpenRouter's video API, and the local
/// ledger row for what it cost.
///
/// Every clip goes to OpenRouter (product owner, 2026-09-27: "it can just be done
/// via openrouter"). A clip takes eleven seconds to six minutes, so nobody
/// holds a request open: a job is started, polled and downloaded. On the
/// learner's own OpenRouter key the app does that with OpenRouter directly;
/// otherwise the managed proxy's job route (`workers/ai-proxy`,
/// `/v1/video/generations`) does it with ForeverLM's key and debits the
/// account OpenRouter's reported cost the first time a poll finds the clip
/// done. Nothing here decides which model: the caller passes the account's
/// Settings choice.
enum ManagedVideoGeneration {
    enum Failure: LocalizedError, Sendable {
        case notSignedIn
        case emptyPrompt
        case providerRejected(String)
        case generationFailed(String)
        case timedOut
        case noVideoReturned

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in with Apple to use ForeverLM AI."
            case .emptyPrompt:
                return "The video request had no prompt."
            case .providerRejected(let reason):
                return reason
            case .generationFailed(let reason):
                return reason
            case .timedOut:
                return "The video took too long to generate."
            case .noVideoReturned:
                return "The model returned no video."
            }
        }
    }

    private static let logger = Logger(subsystem: "com.foreverlm", category: "VideoGeneration")
    static let jobPath = "/v1/video/generations"

    /// How the poll paces itself: quick at first, then every eight seconds,
    /// for at most this long — twice the slowest model's usual worst case.
    static let pollIntervals: [TimeInterval] = [4, 4, 4, 6, 6, 8]
    static let maximumWait: TimeInterval = 12 * 60

    /// Draws one clip and returns its bytes once the proxy has debited it.
    ///
    /// - Parameters:
    ///   - usageTask: the feature label the ledger files the charge under
    ///     (`explainer_video`), so Settings → AI activity can say what the money
    ///     bought.
    ///   - source: the library record the clip is for, when there is one.
    static func generateClip(
        prompt: String,
        model: VideoGenerationModel,
        resolution: VideoGenerationCatalog.Resolution,
        durationSeconds: Int? = nil,
        usageTask: String,
        source: AIUsageSource? = nil
    ) async throws -> GeneratedVideoClip {
        guard ManagedAI.isSignedIn else { throw Failure.notSignedIn }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyPrompt }
        let resolved = try await VideoGenerationDirectory.resolve(model)
        let duration = durationSeconds ?? resolved.clipSeconds

        return try await AIUsageAttribution.$task.withValue(usageTask) {
            try await ManagedImageGeneration.withOptionalSource(source) {
                // Built inside the closure: the body is not Sendable.
                let body = requestBody(prompt: trimmed, model: resolved, resolution: resolution, durationSeconds: duration)
                // An own OpenRouter key films with OpenRouter directly and
                // pays for it (product owner, 2026-09-22: "users should be able to
                // bring their own key for everything that is openrouter
                // enabled"); otherwise the proxy films with ForeverLM's key.
                if ManagedAI.sendsOwnKeyDirect(toHost: ManagedAI.OwnKeyRouter.openRouter.host) {
                    return try await generateOnOpenRouter(body: body, model: resolved, durationSeconds: duration)
                }
                let job = try await start(body: body)
                let ready = try await waitUntilReady(job: job)
                let data = try await download(job: job)
                await recordUsage(ready, model: resolved, durationSeconds: duration)
                return GeneratedVideoClip(
                    data: data,
                    durationSeconds: duration,
                    costUSD: ready.costUSD,
                    requestID: ready.requestID
                )
            }
        }
    }

    /// One OpenRouter video body, carrying only what `model` lists: the
    /// explainer's 16:9 (or the nearest ratio it offers), the resolution, the
    /// clip length, and sound for a model that takes `generate_audio`. The
    /// proxy's job route takes the same body and checks it against the same
    /// directory before it forwards it.
    static func requestBody(
        prompt: String,
        model: VideoGenerationModel,
        resolution: VideoGenerationCatalog.Resolution,
        durationSeconds: Int
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.id,
            "prompt": prompt,
            "duration": durationSeconds,
        ]
        if !model.resolutions.isEmpty { body["resolution"] = resolution.rawValue }
        if model.aspectRatios.contains(VideoGenerationCatalog.aspectRatio) {
            body["aspect_ratio"] = VideoGenerationCatalog.aspectRatio
        } else if let nearest = nearestRatio(to: VideoGenerationCatalog.aspectRatio, among: model.aspectRatios) {
            body["aspect_ratio"] = nearest
        }
        if model.takesGenerateAudio { body["generate_audio"] = true }
        return body
    }

    private static func nearestRatio(to wanted: String, among offered: [String]) -> String? {
        guard let target = ImageGenerationCatalog.Shape.ratio(wanted) else { return nil }
        return offered
            .compactMap { value in ImageGenerationCatalog.Shape.ratio(value).map { (value, abs(log($0) - log(target))) } }
            .min { $0.1 < $1.1 }?
            .0
    }

    // MARK: - The job route

    struct Job: Sendable {
        let token: String
        let requestID: String?
        let costUSD: Double?
    }

    struct Ready: Sendable {
        let requestID: String?
        let costUSD: Double?
    }

    private struct StartResponse: Decodable {
        let job: String
        let status: String
        let requestID: String?
        let costUSD: Double?
        enum CodingKeys: String, CodingKey {
            case job, status
            case requestID = "request_id"
            case costUSD = "cost_usd"
        }
    }

    private struct StatusResponse: Decodable {
        struct Error: Decodable {
            let code: String
            let message: String
        }
        let status: String
        let requestID: String?
        let costUSD: Double?
        let error: Error?
        enum CodingKeys: String, CodingKey {
            case status, error
            case requestID = "request_id"
            case costUSD = "cost_usd"
        }
    }

    private static func start(body: [String: Any]) async throws -> Job {
        var request = try ManagedAI.billableProxyRequest(path: jobPath, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data, what: "start the video")
        let decoded = try JSONDecoder().decode(StartResponse.self, from: data)
        return Job(token: decoded.job, requestID: decoded.requestID, costUSD: decoded.costUSD)
    }

    private static func waitUntilReady(job: Job) async throws -> Ready {
        let deadline = Date().addingTimeInterval(maximumWait)
        var step = 0
        while true {
            try Task.checkCancellation()
            let interval = pollIntervals[min(step, pollIntervals.count - 1)]
            step += 1
            try await Task.sleep(for: .seconds(interval))
            var request = try ManagedAI.billableProxyRequest(path: "\(jobPath)/\(job.token)", method: "GET")
            request.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.data(for: request)
            try check(response, data: data, what: "report the video's progress")
            let status = try JSONDecoder().decode(StatusResponse.self, from: data)
            switch status.status {
            case "ready":
                return Ready(requestID: status.requestID ?? job.requestID, costUSD: status.costUSD ?? job.costUSD)
            case "failed":
                throw Failure.generationFailed(status.error?.message ?? "OpenRouter could not generate the video.")
            default:
                if Date() >= deadline { throw Failure.timedOut }
            }
        }
    }

    private static func download(job: Job) async throws -> Data {
        var request = try ManagedAI.billableProxyRequest(path: "\(jobPath)/\(job.token)/content", method: "GET")
        request.timeoutInterval = 300
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data, what: "hand over the video")
        guard !data.isEmpty else { throw Failure.noVideoReturned }
        return data
    }

    private static func check(_ response: URLResponse, data: Data, what: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw Failure.providerRejected("ForeverLM AI returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let error = ManagedAI.serviceError(from: data) {
                logger.error("Video route refused (\(http.statusCode)) while asked to \(what, privacy: .public): \(error.code, privacy: .public) \(error.message, privacy: .public)")
                ManagedAI.surfaceIfNeeded(error)
                throw Failure.providerRejected(error.message)
            }
            let text = String(data: data, encoding: .utf8)?.prefix(300).description ?? "HTTP \(http.statusCode)"
            throw Failure.providerRejected("ForeverLM AI could not \(what): \(text)")
        }
    }

    // MARK: - OpenRouter, on the learner's own key

    static let openRouterVideosURL = URL(string: "https://openrouter.ai/api/v1/videos")!

    private struct OpenRouterJob: Decodable {
        struct Usage: Decodable { let cost: Double? }
        struct JobError: Decodable { let message: String? }
        let id: String
        let status: String
        let usage: Usage?
        let error: JobError?
    }

    /// OpenRouter's video jobs: submit, poll until `completed`, download. Every
    /// request is bound for openrouter.ai, which `ManagedAI.rewrite` sends
    /// straight there with the learner's key, so nothing here touches the
    /// balance. The poll answer carries the exact billed cost.
    private static func generateOnOpenRouter(
        body: [String: Any],
        model: VideoGenerationModel,
        durationSeconds: Int
    ) async throws -> GeneratedVideoClip {
        var submit = URLRequest(url: openRouterVideosURL)
        submit.httpMethod = "POST"
        submit.timeoutInterval = 120
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submit.httpBody = try JSONSerialization.data(withJSONObject: body)
        ManagedAI.rewrite(&submit)
        let (submitted, submitResponse) = try await URLSession.shared.data(for: submit)
        try checkOpenRouter(submitResponse, data: submitted, what: "start the video")
        let job = try JSONDecoder().decode(OpenRouterJob.self, from: submitted)
        let jobURL = openRouterVideosURL.appendingPathComponent(job.id)

        let deadline = Date().addingTimeInterval(maximumWait)
        var step = 0
        var cost: Double?
        while true {
            try Task.checkCancellation()
            let interval = pollIntervals[min(step, pollIntervals.count - 1)]
            step += 1
            try await Task.sleep(for: .seconds(interval))
            var poll = URLRequest(url: jobURL)
            poll.timeoutInterval = 60
            ManagedAI.rewrite(&poll)
            let (data, response) = try await URLSession.shared.data(for: poll)
            try checkOpenRouter(response, data: data, what: "report the video's progress")
            let status = try JSONDecoder().decode(OpenRouterJob.self, from: data)
            if status.status == "completed" {
                cost = status.usage?.cost
                break
            }
            if status.status == "failed" {
                throw Failure.generationFailed(status.error?.message ?? "OpenRouter could not generate the video.")
            }
            if Date() >= deadline { throw Failure.timedOut }
        }

        var download = URLRequest(url: jobURL.appendingPathComponent("content"))
        download.timeoutInterval = 300
        ManagedAI.rewrite(&download)
        let (video, downloadResponse) = try await URLSession.shared.data(for: download)
        try checkOpenRouter(downloadResponse, data: video, what: "hand over the video")
        guard !video.isEmpty else { throw Failure.noVideoReturned }

        let ready = Ready(requestID: nil, costUSD: cost)
        await recordUsage(ready, model: model, durationSeconds: durationSeconds, provider: "OpenRouter")
        return GeneratedVideoClip(data: video, durationSeconds: durationSeconds, costUSD: cost, requestID: nil)
    }

    private static func checkOpenRouter(_ response: URLResponse, data: Data, what: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw Failure.providerRejected("OpenRouter returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = AIProviderErrorText.fromResponseBody(data) ?? "HTTP \(http.statusCode)"
            logger.error("OpenRouter video refused (\(http.statusCode)) while asked to \(what, privacy: .public)")
            throw Failure.providerRejected("OpenRouter could not \(what): \(detail)")
        }
    }

    /// The local mirror of the proxy's debit, so Settings → AI activity shows
    /// the clip with the figure the account was actually charged.
    private static func recordUsage(
        _ ready: Ready,
        model: VideoGenerationModel,
        durationSeconds: Int,
        provider: String = "OpenRouter"
    ) async {
        let report = AIUsageReport(
            durationSeconds: Double(durationSeconds),
            providerReportedCost: ready.costUSD,
            currency: ready.costUSD == nil ? nil : "USD"
        )
        do {
            try await AIUsageTracker.shared.record(
                provider: provider,
                model: model.id,
                operation: "video_generation",
                report: report,
                task: AIUsageAttribution.task ?? GeneratedExplainerVideo.usageTask
            )
        } catch {
            logger.warning("Video clip usage was not recorded locally: \(error.localizedDescription, privacy: .public)")
        }
    }
}

