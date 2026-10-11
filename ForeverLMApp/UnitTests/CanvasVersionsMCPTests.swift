import Foundation
import Testing
@testable import ForeverLM

@Suite("MCP: a canvas's versions and export", .serialized)
@MainActor
struct CanvasVersionsMCPTests {
    /// A Studio view model over a store of its own, bound as the one the MCP
    /// tools answer from, with the layout rows kept in a suite of their own.
    private func withStudio(_ body: (StudioViewModel) async throws -> Void) async throws {
        let suiteName = "CanvasVersionsMCPTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasVersionsMCPTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vm = StudioViewModel(storageService: StorageService(storeRoot: root))
        AppModelBridge.studio = vm
        defer {
            CanvasAutoVersions.shared.forgetAll()
            AppModelBridge.studio = nil
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: defaults)) {
            try await body(vm)
        }
    }

    @Test("list, save and restore: a version keeps the canvas, a restore puts it back as one edit that Undo takes back, after keeping what was there")
    func flow() async throws {
        try await withStudio { vm in
            let canvas = vm.createCanvas(named: "Ideas")
            vm.showCanvas(canvas.id)
            let model = vm.knowledgeMap
            model.place([(ref: "idea:a", x: 0, y: 0), (ref: "idea:b", x: 300, y: 0)])

            let empty = try await MCPDataStore.listCanvasVersions(canvasID: nil)
            #expect(empty["version_count"] as? Int == 0)
            #expect((empty["canvas"] as? [String: Any])?["canvas_id"] as? String == canvas.id)
            let current = try #require(empty["current"] as? [String: Any])
            #expect(current["cards"] as? Int == 2)
            #expect(current["changed_since_newest_version"] as? Int == 2, "everything is new against no version")

            let saved = try await MCPDataStore.saveCanvasVersion(canvasID: nil, name: "  Two   ideas ")
            let version = try #require(saved["version"] as? [String: Any])
            #expect(version["name"] as? String == "Two ideas")
            #expect(version["kind"] as? String == "manual")
            #expect(version["cards"] as? Int == 2)
            let versionID = try #require(version["version_id"] as? String)

            // Rearranged since: an Idea taken off and another put on.
            model.place([(ref: "idea:c", x: 600, y: 0)])
            model.unplace(["idea:a"])
            let after = try await MCPDataStore.listCanvasVersions(canvasID: canvas.id)
            #expect(after["version_count"] as? Int == 1)
            #expect((after["current"] as? [String: Any])?["changed_since_newest_version"] as? Int == 2)

            let restored = try await MCPDataStore.restoreCanvasVersion(canvasID: nil, versionID: versionID)
            #expect(restored["restored"] as? Bool == true)
            #expect(Set(model.layout.placements.keys) == ["idea:a", "idea:b"])
            let keptBefore = try #require(restored["kept_before_restore"] as? [String: Any])
            #expect(keptBefore["kind"] as? String == "auto", "what the canvas held is kept first")
            #expect(keptBefore["cards"] as? Int == 2)
            let keptID = try #require(keptBefore["version_id"] as? String)
            #expect(model.canUndo)

            // One edit: Undo takes it back whole.
            model.undo()
            #expect(Set(model.layout.placements.keys) == ["idea:b", "idea:c"])

            // The kept version is what the canvas holds: nothing to do, and no copy of it.
            let again = try await MCPDataStore.restoreCanvasVersion(canvasID: nil, versionID: keptID)
            #expect(again["restored"] as? Bool == false)
            #expect(try await vm.canvasVersions(of: canvas.id).count == 2)
        }
    }

    @Test("A version of a canvas that is not open is saved from its row, and a restore opens the canvas, where Undo lives")
    func otherCanvas() async throws {
        try await withStudio { vm in
            let first = vm.createCanvas(named: "First")
            let second = vm.createCanvas(named: "Second")
            vm.showCanvas(first.id)
            vm.knowledgeMap.place([(ref: "idea:a", x: 0, y: 0)])
            vm.showCanvas(second.id)
            vm.knowledgeMap.place([(ref: "idea:x", x: 0, y: 0), (ref: "idea:y", x: 300, y: 0)])

            let saved = try await MCPDataStore.saveCanvasVersion(canvasID: first.id, name: "Before")
            #expect((saved["version"] as? [String: Any])?["cards"] as? Int == 1, "the first canvas's row, not the open one's")
            #expect(vm.knowledgeMap.mapID == second.id, "saving opens nothing")
            let versionID = try #require((saved["version"] as? [String: Any])?["version_id"] as? String)
            #expect(try await vm.canvasVersions(of: second.id).isEmpty, "each canvas has its own versions")

            let restored = try await MCPDataStore.restoreCanvasVersion(canvasID: first.id, versionID: versionID)
            #expect(restored["restored"] as? Bool == false, "it already is that")
            #expect(vm.knowledgeMap.mapID == first.id, "a restore opens the canvas")
        }
    }

    @Test("An unknown canvas or version is refused with the tool that lists them, and Delete Forever takes a canvas's versions with it")
    func refusalsAndDeletion() async throws {
        try await withStudio { vm in
            let canvas = vm.createCanvas(named: "Gone soon")
            vm.showCanvas(canvas.id)
            vm.knowledgeMap.place([(ref: "idea:a", x: 0, y: 0)])
            await #expect(throws: MCPError.self) { _ = try await MCPDataStore.listCanvasVersions(canvasID: "cnv-nope") }
            do {
                _ = try await MCPDataStore.restoreCanvasVersion(canvasID: nil, versionID: "1-manual.json")
                Issue.record("an unknown version was restored")
            } catch {
                #expect(error.localizedDescription.contains("list_canvas_versions"), "\(error.localizedDescription)")
            }

            _ = try await MCPDataStore.saveCanvasVersion(canvasID: nil, name: "Keep")
            #expect(try await vm.canvasVersions(of: canvas.id).count == 1)
            vm.moveCanvasesToTrash([canvas.id])
            vm.deleteCanvasesForever([canvas.id])
            // The history goes on the storage actor; the next call waits for it.
            var left = try await vm.canvasVersions(of: canvas.id)
            for _ in 0..<50 where !left.isEmpty {
                try await Task.sleep(nanoseconds: 20_000_000)
                left = try await vm.canvasVersions(of: canvas.id)
            }
            #expect(left.isEmpty)
        }
    }

    @Test("The three tools are registered, off the store gate, and grouped with the Canvas's own; restoring needs a version_id")
    func registration() {
        let tools = MCPToolRegistry().tools
        for name in MCPToolRegistry.canvasVersionToolNames {
            #expect(tools.contains { $0.name == name }, "\(name) is registered")
        }
        #expect(MCPToolRegistry.canvasEditToolNames.isSuperset(of: ["save_canvas_version", "restore_canvas_version"]))
        #expect(MCPToolRegistry.canvasCatalogToolNames.contains("list_canvas_versions"))
        #expect(MCPToolRegistry.storeGateExemptToolNames.isSuperset(of: MCPToolRegistry.canvasVersionToolNames))
        let restore = tools.first { $0.name == "restore_canvas_version" }
        #expect(restore?.inputSchema["required"] as? [String] == ["version_id"])
        for name in MCPToolRegistry.canvasVersionToolNames {
            let schema = tools.first { $0.name == name }?.inputSchema ?? [:]
            for key in ["anyOf", "oneOf", "allOf"] { #expect(schema[key] == nil, "\(name) has a top-level \(key)") }
        }
    }

    @Test("A canvas that is not open, or has nothing on it, is not drawn, and says why; the exporter's scale and refs reach it")
    func exportErrors() async throws {
        try await withStudio { vm in
            let canvas = vm.createCanvas(named: "Sketch")
            let other = vm.createCanvas(named: "Other")
            vm.showCanvas(canvas.id)

            do {
                _ = try await vm.exportCanvasImageData(canvasID: other.id, scale: 2)
                Issue.record("a canvas that is not open was drawn")
            } catch {
                #expect(error as? CanvasExportError == .notOpen(name: "Other"))
            }
            do {
                _ = try await vm.exportCanvasImageData(canvasID: canvas.id, scale: 2)
                Issue.record("a canvas no pane draws was drawn")
            } catch {
                #expect(error as? CanvasExportError == .notShowing(name: "Sketch"))
            }

            let model = vm.knowledgeMap
            defer { model.imageExporter = nil }
            var asked: [(Double, [String]?)] = []
            model.imageExporter = { scale, refs in
                asked.append((scale, refs))
                return Data([0x89, 0x50, 0x4E, 0x47])
            }
            do {
                _ = try await vm.exportCanvasImageData(canvasID: canvas.id, scale: 2)
                Issue.record("an empty canvas was drawn")
            } catch {
                #expect(error as? CanvasExportError == .nothingToDraw(name: "Sketch"))
            }
            vm.knowledgeMap.place([(ref: "idea:a", x: 0, y: 0)])
            let whole = try await vm.exportCanvasImageData(canvasID: canvas.id, scale: 2)
            let part = try await vm.exportCanvasImageData(canvasID: canvas.id, scale: 1, refs: ["idea:a"])
            #expect(whole == Data([0x89, 0x50, 0x4E, 0x47]) && part == whole)
            #expect(asked.count == 2)
            #expect(asked[0].0 == 2 && asked[0].1 == nil)
            #expect(asked[1].0 == 1 && asked[1].1 == ["idea:a"])
        }
    }
}
