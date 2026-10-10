import Foundation
import Testing
@testable import ForeverLM

@Suite("Provider countries")
struct OpenRouterProviderDirectoryTests {
    /// Rows shaped as `GET /api/v1/providers` answered on 2026-09-28.
    private let json = """
    {"data":[
      {"name":"Alibaba","slug":"alibaba","headquarters":"SG","datacenters":["SG","CN"]},
      {"name":"DeepSeek","slug":"deepseek","headquarters":"CN","datacenters":null},
      {"name":"Krea","slug":"krea","headquarters":"US","datacenters":[]},
      {"name":"AssemblyAI","slug":"assemblyai","headquarters":null,"datacenters":["US"]},
      {"name":"Relace","slug":"relace","headquarters":null,"datacenters":[]},
      {"name":"Odd","slug":"odd","headquarters":"USA","datacenters":["us","US","United States"]}
    ]}
    """

    @Test("A provider's headquarters and data centres are read by slug; one that gives neither is left out")
    func parsesHeadquartersAndDatacenters() throws {
        let locations = try #require(OpenRouterProviderDirectory.parse(Data(json.utf8)))
        #expect(locations["alibaba"] == OpenRouterProviderLocation(headquarters: "SG", datacenters: ["SG", "CN"]))
        #expect(locations["deepseek"] == OpenRouterProviderLocation(headquarters: "CN", datacenters: []))
        #expect(locations["krea"] == OpenRouterProviderLocation(headquarters: "US", datacenters: []))
        #expect(locations["assemblyai"] == OpenRouterProviderLocation(headquarters: nil, datacenters: ["US"]))
        #expect(locations["relace"] == nil)
        // "USA" and "United States" are not region codes, so nothing is made
        // up from them; a code given twice is kept once.
        #expect(locations["odd"]?.headquarters == nil)
        #expect(locations["odd"]?.datacenters == ["US"])
    }

    @Test("A body that is not a provider list is a failed read, not an empty one")
    func rejectsOtherShapes() {
        #expect(OpenRouterProviderDirectory.parse(Data(#"{"error":{"message":"Not Found","code":404}}"#.utf8)) == nil)
        #expect(OpenRouterProviderDirectory.parse(Data("not json".utf8)) == nil)
    }

    @Test("The flag is the headquarters' country, and none when it is unknown")
    func flagFollowsHeadquarters() {
        #expect(OpenRouterProviderLocation(headquarters: "CN", datacenters: []).flag == "🇨🇳")
        #expect(OpenRouterProviderLocation(headquarters: "SG", datacenters: ["SG", "CN"]).flag == "🇸🇬")
        #expect(OpenRouterProviderLocation(headquarters: nil, datacenters: ["US"]).flag == nil)
        #expect(OpenRouterProviderLocation.flag(regionCode: "us") == "🇺🇸")
        #expect(OpenRouterProviderLocation.flag(regionCode: "USA") == nil)
        #expect(OpenRouterProviderLocation.flag(regionCode: "1A") == nil)
    }

    @Test("An endpoint tag names its provider by its first segment")
    func providerSlugFromTag() {
        #expect(OpenRouterProviderDirectory.providerSlug(ofTag: "siliconflow/fp8") == "siliconflow")
        #expect(OpenRouterProviderDirectory.providerSlug(ofTag: "amazon-bedrock/us-west-2") == "amazon-bedrock")
        #expect(OpenRouterProviderDirectory.providerSlug(ofTag: "google-vertex/global/flex") == "google-vertex")
        #expect(OpenRouterProviderDirectory.providerSlug(ofTag: "DeepSeek") == "deepseek")
    }
}
