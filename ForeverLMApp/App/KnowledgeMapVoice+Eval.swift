#if DEBUG
import Foundation

// MARK: - Speaking to the Canvas: the eval (DEBUG only)
//
// Runs spoken requests through the real path (`KnowledgeMapVoice.change`) on
// this Mac's own key, on chosen models, and writes where the time went and
// what each model answered, so the prompt and the model pick are judged by
// measurement rather than by a feeling of speed. Nothing here ships.
//
// Post the distributed notification `com.foreverlm.debug.canvasVoiceEval`
// with the path of a JSON request as its object:
//
//   {"out": "/abs/results.json", "models": ["google/gemini-3.8-flash"] (or
//    omitted: the task's own), "repeats": 1, "apply": false,
//    "cases": [{"id": "group", "said": "put these together", "snapshot": {…}},
//              {"id": "spoken", "audio": "/abs/clip.m4a"}]}
//
// A case without a snapshot reads the open canvas; with `audio` its words are
// transcribed first (the Dictation model, timed). `apply` true carries the
// edits out on the open canvas, as speaking does, capsule and all.

extension KnowledgeMapVoice {
    static let evalNotification = Notification.Name("com.foreverlm.debug.canvasVoiceEval")

    private struct EvalRequest: Decodable {
        struct Case: Decodable {
            var id: String
            var said: String?
            var audio: String?
            /// Hear `audio` on this Mac (`KnowledgeMapVoiceListener`), played
            /// at the pace it was spoken, rather than send it to the
            /// Dictation model.
            var onDevice: Bool?
            var snapshot: CanvasVoice.Snapshot?

            enum CodingKeys: String, CodingKey {
                case id, said, audio, snapshot
                case onDevice = "on_device"
            }
        }

        var out: String
        var models: [String]?
        var repeats: Int?
        var apply: Bool?
        /// Keep the model's hidden thinking, at its lowest effort, to compare
        /// with the learner's path, which turns it off.
        var reasoning: Bool?
        /// MCP tool calls made first (a canvas built and opened to speak to)
        /// and after the cases (the canvas read back), in-app, as chat makes them.
        var tools: [ToolCall]?
        var afterTools: [ToolCall]?
        var cases: [Case]

        enum CodingKeys: String, CodingKey {
            case out, models, repeats, apply, reasoning, tools, cases
            case afterTools = "after_tools"
        }
    }

    private struct ToolCall: Decodable {
        var name: String
        var arguments: [String: Any]

        enum CodingKeys: String, CodingKey { case name, arguments }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            let raw = try container.decodeIfPresent(JSONText.self, forKey: .arguments)
            arguments = raw?.object ?? [:]
        }
    }

    /// Any JSON object, decoded by way of JSONSerialization.
    private struct JSONText: Decodable {
        var object: [String: Any]

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(AnyJSON.self)
            object = value.value as? [String: Any] ?? [:]
        }
    }

    private struct AnyJSON: Decodable {
        var value: Any

        init(from decoder: Decoder) throws {
            if var array = try? decoder.unkeyedContainer() {
                var items: [Any] = []
                while !array.isAtEnd { items.append(try array.decode(AnyJSON.self).value) }
                value = items
            } else if let object = try? decoder.container(keyedBy: Key.self) {
                var items: [String: Any] = [:]
                for key in object.allKeys { items[key.stringValue] = try object.decode(AnyJSON.self, forKey: key).value }
                value = items
            } else {
                let single = try decoder.singleValueContainer()
                if single.decodeNil() { value = NSNull() }
                else if let bool = try? single.decode(Bool.self) { value = bool }
                else if let number = try? single.decode(Double.self) { value = number }
                else { value = try single.decode(String.self) }
            }
        }

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    private func callTools(_ calls: [ToolCall]?) async -> [[String: Any]] {
        var out: [[String: Any]] = []
        let registry = MCPToolRegistry(store: MCPDataStore())
        for call in calls ?? [] {
            // Timings the eval takes of the Canvas itself, not tools.
            if call.name == "debug.refresh_canvas_content", let studio = AppModelBridge.studio {
                let started = Date()
                await studio.refreshKnowledgeMapContent()
                out.append(["name": call.name, "result": [
                    "ms": Int(Date().timeIntervalSince(started) * 1000),
                    "nodes": studio.knowledgeMap.content.nodes.count,
                ]])
                continue
            }
            // The capsule as it stands, and its Undo pressed.
            if call.name == "debug.voice_state" || call.name == "debug.voice_undo" {
                let offered = canUndoRequest
                if call.name == "debug.voice_undo" { undoRequest() }
                out.append(["name": call.name, "result": [
                    "phase": "\(phase)", "offered_undo": offered, "offers_undo": canUndoRequest,
                    "changes": changes, "placed": AppModelBridge.studio?.knowledgeMap.layout.placements.count ?? -1,
                ] as [String: Any]])
                continue
            }
            let text = await registry.callTool(name: call.name, arguments: call.arguments, access: .internalFullAccess)
            let parsed = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            out.append(["name": call.name, "result": parsed ?? text])
        }
        return out
    }

    /// Listens for eval requests; called once, when the controller is made.
    func listenForEvals() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.evalNotification, object: nil, queue: .main
        ) { note in
            guard let path = note.object as? String else { return }
            Task { @MainActor in await KnowledgeMapVoice.shared.runEval(at: path) }
        }
    }

    private func runEval(at path: String) async {
        let request: EvalRequest
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            request = try JSONDecoder().decode(EvalRequest.self, from: data)
        } catch {
            Self.write(["error": "Could not read \(path): \(error.localizedDescription)"], to: path + ".error.json")
            return
        }
        let models: [String?] = request.models.map { $0.map(Optional.some) } ?? [nil]
        let before = await callTools(request.tools)
        var results: [[String: Any]] = []
        for model in models {
            for item in request.cases {
                for attempt in 0..<max(request.repeats ?? 1, 1) {
                    var began = Date()
                    var said = item.said ?? ""
                    var transcriptionError: String?
                    var heardOnDevice = false
                    if let audio = item.audio {
                        do {
                            if item.onDevice == true {
                                guard #available(macOS 26.0, *), let locale = await KnowledgeMapVoiceListener.locale(),
                                      await KnowledgeMapVoiceListener.isReady(for: locale) else {
                                    throw MCPError.invalidInput("This Mac has no speech model for its language (yet).")
                                }
                                let listener = KnowledgeMapVoiceListener()
                                try await listener.start(locale: locale, recording: URL(fileURLWithPath: audio))
                                // Played to its end: this is the learner letting go.
                                began = Date()
                                said = await listener.finish()
                                heardOnDevice = true
                            } else {
                                said = try await dictation.transcribeProbe(fileURL: URL(fileURLWithPath: audio))
                            }
                        } catch {
                            transcriptionError = error.localizedDescription
                        }
                    }
                    let transcribed = Date()
                    var row: [String: Any] = ["case": item.id, "attempt": attempt, "requested_model": model ?? NSNull(), "heard_on_device": heardOnDevice]
                    if let transcriptionError {
                        row["error"] = transcriptionError
                        results.append(row)
                        continue
                    }
                    let id = beginEvalRequest(said: said, showing: request.apply == true)
                    let report = await change(
                        said, id: id, began: began, transcribed: transcribed,
                        applying: request.apply == true, model: model, snapshot: item.snapshot,
                        reasoning: request.reasoning == true
                    )
                    row.merge(Self.json(report)) { _, new in new }
                    results.append(row)
                    Self.write(["done": false, "results": results, "tools": before], to: request.out)
                }
            }
        }
        let after = await callTools(request.afterTools)
        Self.write(["done": true, "results": results, "tools": before, "after_tools": after], to: request.out)
    }

    private static func json(_ report: Report) -> [String: Any] {
        var row: [String: Any] = [
            "model": report.model,
            "said": report.said,
            "lines": report.lines,
            "edits": report.edits.map { ["tool": $0.tool, "arguments": $0.arguments] as [String: Any] },
            "done": report.done,
            "failures": report.failures,
            "unreadable": report.unreadable,
            "hedged": report.hedged,
        ]
        let numbers: [(String, Int?)] = [
            ("transcribe_ms", report.transcribeMS), ("context_ms", report.contextMS),
            ("first_token_ms", report.firstTokenMS), ("model_ms", report.modelMS),
            ("first_edit_ms", report.firstEditMS), ("total_ms", report.totalMS),
        ]
        for (key, value) in numbers { row[key] = value ?? NSNull() }
        if let remark = report.remark { row["remark"] = remark }
        if let refused = report.refused { row["refused"] = refused }
        return row
    }

    private static func write(_ object: [String: Any], to path: String) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
#endif
