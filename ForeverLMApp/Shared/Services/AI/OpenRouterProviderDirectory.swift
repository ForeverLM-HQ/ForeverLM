import Foundation

/// Where an OpenRouter provider says it is, as `GET /api/v1/providers` lists
/// it: the country the company is based in and the countries of its data
/// centres, each an ISO 3166-1 alpha-2 code. It describes the company, not one
/// endpoint, and the provider declares it itself, so nothing routes on it —
/// keeping work in a region is `OpenRouterRegionalEndpoints`' job. Checked
/// 2026-09-28: 74 of 111 providers give a headquarters and 27 their data
/// centres (Alibaba: based in Singapore, running in Singapore and China).
struct OpenRouterProviderLocation: Sendable, Equatable {
    /// "US", "CN"; nil when OpenRouter does not say.
    let headquarters: String?
    /// Empty when OpenRouter does not say, whether the row had null or `[]`.
    let datacenters: [String]

    /// The headquarters' flag, e.g. "🇨🇳"; nil when the country is unknown.
    var flag: String? {
        headquarters.flatMap(Self.flag(regionCode:))
    }

    /// The emoji flag for a two-letter region code; nil for anything else.
    static func flag(regionCode: String) -> String? {
        let letters = regionCode.uppercased().unicodeScalars
        guard letters.count == 2, letters.allSatisfy({ (65...90).contains($0.value) }) else { return nil }
        var flag = String.UnicodeScalarView()
        for letter in letters {
            guard let indicator = Unicode.Scalar(0x1F1E6 + letter.value - 65) else { return nil }
            flag.append(indicator)
        }
        return String(flag)
    }

    /// "Singapore" for "SG", in the learner's language; the code itself when
    /// the system has no name for it.
    static func countryName(_ regionCode: String) -> String {
        Locale.current.localizedString(forRegionCode: regionCode) ?? regionCode
    }
}

/// OpenRouter's provider list, read once and kept in memory: the host
/// picker's flags come from it. It needs no key. A failed read keeps the last
/// list; with none, the picker simply shows no flags.
actor OpenRouterProviderDirectory {
    static let shared = OpenRouterProviderDirectory()

    private static let url = OpenRouterAPI.providers
    /// A provider's country rarely changes, so a list half a day old is fine.
    private static let freshnessInterval: TimeInterval = 12 * 60 * 60

    private var cached: (locations: [String: OpenRouterProviderLocation], fetchedAt: Date)?
    private var inFlight: Task<[String: OpenRouterProviderLocation], Error>?

    /// The provider a model endpoint belongs to: its tag's first segment,
    /// which OpenRouter keeps equal to the provider's slug ("siliconflow" for
    /// "siliconflow/fp8", "amazon-bedrock" for "amazon-bedrock/us-west-2").
    nonisolated static func providerSlug(ofTag tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
    }

    /// Every provider OpenRouter lists that says where it is, keyed by slug.
    func locations() async throws -> [String: OpenRouterProviderLocation] {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < Self.freshnessInterval {
            return cached.locations
        }
        if let inFlight { return try await inFlight.value }
        let task = Task<[String: OpenRouterProviderLocation], Error> { try await Self.fetch() }
        inFlight = task
        defer { inFlight = nil }
        do {
            let locations = try await task.value
            cached = (locations, Date())
            return locations
        } catch {
            if let cached { return cached.locations }
            throw error
        }
    }

    private static func fetch() async throws -> [String: OpenRouterProviderLocation] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let locations = parse(data) else { throw URLError(.cannotParseResponse) }
        return locations
    }

    /// Nil when the body is not a provider list. A provider that gives
    /// neither a headquarters nor a data centre is left out, and so is a code
    /// that is not two letters.
    static func parse(_ data: Data) -> [String: OpenRouterProviderLocation]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]]
        else { return nil }
        func code(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  OpenRouterProviderLocation.flag(regionCode: text) != nil
            else { return nil }
            return text
        }
        var locations: [String: OpenRouterProviderLocation] = [:]
        for row in rows {
            guard let slug = (row["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !slug.isEmpty
            else { continue }
            let headquarters = code(row["headquarters"])
            var datacenters: [String] = []
            for value in row["datacenters"] as? [Any] ?? [] {
                if let country = code(value), !datacenters.contains(country) { datacenters.append(country) }
            }
            guard headquarters != nil || !datacenters.isEmpty else { continue }
            locations[slug] = OpenRouterProviderLocation(headquarters: headquarters, datacenters: datacenters)
        }
        return locations
    }
}
