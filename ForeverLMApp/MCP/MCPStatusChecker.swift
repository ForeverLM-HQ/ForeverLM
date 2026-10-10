import Foundation
import OSLog

/// Polls the MCP server health endpoint to report tunnel status.
///
/// Main-actor isolated like `MCPServerLauncher`, whose `tunnelURL` it reads.
@Observable
@MainActor
final class MCPStatusChecker {
    static let shared = MCPStatusChecker()

    enum Status: Equatable {
        case unknown
        case checking
        case running
        case unreachable
    }

    private(set) var status: Status = .unknown
    private(set) var successfulURL: URL?

    private let logger = Logger(subsystem: "ForeverLM", category: "MCPStatus")

    /// Check the public hosted relay used by every external MCP client.
    @discardableResult
    func checkHostedTunnel() async -> Bool {
        status = .checking
        successfulURL = nil

        #if os(macOS)
        let urls: [URL] = [
            MCPServerLauncher.shared.tunnelURL.flatMap { URL(string: "\($0)/health") },
            KeychainService.load(.mcpTunnelURL).flatMap { URL(string: "\($0)/health") },
        ].compactMap { $0 }
        #else
        let urls: [URL] = []
        #endif

        for url in urls {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    successfulURL = url
                    status = .running
                    return true
                }
            } catch {
                logger.debug("Hosted MCP health check failed for \(url): \(error.localizedDescription)")
            }
        }

        successfulURL = nil
        status = .unreachable
        return false
    }

    @discardableResult
    func waitForHostedTunnel(timeout: Duration = .seconds(20)) async -> Bool {
        let start = ContinuousClock.now
        repeat {
            if await checkHostedTunnel() {
                return true
            }
            try? await Task.sleep(for: .seconds(2))
        } while start.duration(to: ContinuousClock.now) < timeout

        successfulURL = nil
        status = .unreachable
        return false
    }
}
