// Which addresses ForeverLM fetches on a caller's behalf.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A URL import names an address and ForeverLM fetches it: from the app, and
/// from any MCP client, local or remote, that asks `add_source`,
/// `attach_pdf_to_paper` or `import_paper_from_url` to. An address on this
/// Mac or its network (a router's admin page, a local service, ForeverLM's own
/// loopback ports) is never one: an import refuses it before the fetch and at
/// every redirect (security audit, 2026-11-12).
enum OutboundAddressPolicy {
    enum Refusal: LocalizedError, Equatable {
        case privateAddress(String)

        var errorDescription: String? {
            switch self {
            case .privateAddress(let host):
                return "ForeverLM does not import from \(host): it is an address on this Mac or its local network."
            }
        }
    }

    /// Throws when an http(s) `url` names a host that is not public, by name
    /// or by any address its name resolves to, and for a `file:` URL, which
    /// URLSession would read off this Mac. Another scheme is left to the
    /// fetch, which does not speak it.
    static func check(_ url: URL) async throws {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "file" { throw Refusal.privateAddress(url.absoluteString) }
        guard scheme == "http" || scheme == "https" else { return }
        guard let host = url.host, !host.isEmpty else {
            throw Refusal.privateAddress(url.absoluteString)
        }
        guard isPublicHostName(host) else { throw Refusal.privateAddress(host) }
        let resolved = await Task.detached(priority: .utility) { resolvedAddresses(of: host) }.value
        guard resolved.allSatisfy(isPublicAddress) else { throw Refusal.privateAddress(host) }
    }

    /// The same check, synchronously, for a redirect: URLSession asks its
    /// delegate on a background queue.
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, isPublicHostName(host) else { return false }
        return resolvedAddresses(of: host).allSatisfy(isPublicAddress)
    }

    /// False for a name that can only mean this Mac or its network, and for an
    /// address literal that is not public. A name that needs DNS is true here;
    /// `check` resolves it.
    static func isPublicHostName(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return false }
        if host == "localhost" { return false }
        for suffix in [".localhost", ".local", ".internal", ".home.arpa", ".lan", ".intranet"] where host.hasSuffix(suffix) {
            return false
        }
        if let literal = addressLiteral(host) { return isPublicAddress(literal) }
        // A bare word with no dot never reaches the public internet.
        return host.contains(".") || host.contains(":")
    }

    /// An IPv4 address as 4 bytes or an IPv6 address as 16, parsed the way
    /// the network stack would: `inet_aton` also reads `2130706433` and `0x7f.1`.
    static func addressLiteral(_ host: String) -> [UInt8]? {
        var v6 = in6_addr()
        if host.contains(":"), inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: v6) { Array($0) }
        }
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 {
            return withUnsafeBytes(of: v4.s_addr) { Array($0) }
        }
        return nil
    }

    /// Whether 4 (IPv4) or 16 (IPv6) bytes are a public unicast address.
    static func isPublicAddress(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 { return isPublicIPv4(bytes) }
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }                         // ::
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false } // ::1
        // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d)
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && (bytes[10..<12].allSatisfy { $0 == 0xff } || bytes[10..<12].allSatisfy { $0 == 0 }) {
            return isPublicIPv4(Array(bytes[12..<16]))
        }
        // NAT64 (64:ff9b::/96) carries an IPv4 address too.
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xff, bytes[3] == 0x9b {
            return isPublicIPv4(Array(bytes[12..<16]))
        }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false }        // fe80::/10 link-local
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0 { return false }        // fec0::/10 site-local
        if (bytes[0] & 0xfe) == 0xfc { return false }                             // fc00::/7 unique local
        if bytes[0] == 0xff { return false }                                      // multicast
        return true
    }

    private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _): return false
        case (100, 64...127): return false                                        // carrier-grade NAT
        case (169, 254): return false                                             // link-local, cloud metadata
        case (172, 16...31): return false
        case (192, 168): return false
        case (192, 0) where b[2] == 0 || b[2] == 2: return false
        case (198, 18...19): return false                                         // benchmarking
        case (198, 51) where b[2] == 100, (203, 0) where b[2] == 113: return false
        case (224...255, _): return false                                         // multicast, reserved, broadcast
        default: return true
        }
    }

    /// Every address `host` resolves to; empty when it does not resolve (the
    /// fetch then fails on its own).
    static func resolvedAddresses(of host: String) -> [[UInt8]] {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let literal = addressLiteral(bare) { return [literal] }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(bare, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var out: [[UInt8]] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let addr = info.pointee.ai_addr {
                switch Int32(addr.pointee.sa_family) {
                case AF_INET:
                    addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        out.append(withUnsafeBytes(of: $0.pointee.sin_addr.s_addr) { Array($0) })
                    }
                case AF_INET6:
                    addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        out.append(withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) })
                    }
                default:
                    break
                }
            }
            cursor = info.pointee.ai_next
        }
        return out
    }

    /// A URLSession delegate that stops a redirect to an address `check`
    /// would refuse. The session then hands back the 3xx response itself,
    /// which every caller already treats as a failed fetch.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url, OutboundAddressPolicy.isAllowed(url) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    static let redirectGuard = RedirectGuard()
}
