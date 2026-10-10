import Foundation

enum MCPRuntimeCoordinator {
    @discardableResult
    static func startPreferredRuntime() async -> Bool {
        // The server, the relay and the writers behind them start only after the library's generation-2
        // activation has finished (docs/cloudkit-schema-design.md §13.3 step 3); open under generation 1.
        await GenerationActivationGate.shared.waitUntilOpen()
        await MCPServerLauncher.shared.autoStart()
        return true
    }

    @discardableResult
    static func startHostedTunnel(takingOver: Bool = false) async -> Bool {
        await GenerationActivationGate.shared.waitUntilOpen()
        await MCPServerLauncher.shared.startHostedTunnel(takingOver: takingOver)
        return true
    }

    static func stopAll() async {
        await MCPServerLauncher.shared.stop()
    }
}
