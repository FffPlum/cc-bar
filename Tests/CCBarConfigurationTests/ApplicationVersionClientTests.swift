import Foundation
import Testing
@testable import CCBarConfiguration

struct ApplicationVersionClientTests {
    @Test func semanticVersionPrecedenceAndBuildMetadata() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
                       "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "2.0.0"]
        for (installed, latest) in zip(ordered, ordered.dropFirst()) {
            #expect(ApplicationVersionClient.compare(installed: installed, latest: latest) == .orderedAscending)
            #expect(ApplicationVersionClient.compare(installed: latest, latest: installed) == .orderedDescending)
        }
        #expect(ApplicationVersionClient.compare(installed: "v1.2.3+build.7", latest: "1.2.3+build.99") == .orderedSame)
        #expect(ApplicationVersionClient.compare(installed: "1.0.0-9999999999999999999999", latest: "1.0.0-10000000000000000000000") == .orderedAscending)
    }

    @Test(arguments: ["", "latest", "dev", "1.2", "01.2.3", "1.2.3.4", "1.2.3-01", "1.2.3+", "999999999999999999999.0.0"])
    func unknownVersionsCannotBeReportedAsCurrent(_ value: String) {
        #expect(ApplicationVersionClient.compare(installed: value, latest: "1.2.3") == nil)
        #expect(ApplicationVersionClient.compare(installed: "1.2.3", latest: value) == nil)
    }

    @Test func sourceFollowsInstalledPackageManager() throws {
        let kimi = try #require(ManagedApplicationCatalog.application("kimi"))
        #expect(ApplicationVersionClient.source(for: kimi, installation: installation("kimi", .uv, "kimi-cli")) == .pypi("kimi-cli"))
        #expect(ApplicationVersionClient.source(for: kimi, installation: installation("kimi", .npm, "@moonshot-ai/kimi-code")) == .npm("@moonshot-ai/kimi-code"))
        let claude = try #require(ManagedApplicationCatalog.application("claude"))
        let formula = ApplicationInstallation(catalogID: "claude", path: "/test/bin/claude",
                                             resolvedPath: "/test/Cellar/claude-code/1.2.3/bin/claude",
                                             source: .homebrew, package: "claude-code")
        #expect(ApplicationVersionClient.source(for: claude, installation: formula) == .homebrew("claude-code", cask: false))
        #expect(ApplicationVersionClient.source(for: claude, installation: installation("claude", .homebrew, "claude-code@latest")) == .homebrew("claude-code@latest", cask: true))
        let pi = try #require(ManagedApplicationCatalog.application("pi"))
        #expect(ApplicationVersionClient.source(for: pi, installation: installation("pi", .npm, "@badlogic/pi-coding-agent")) == .npm("@badlogic/pi-coding-agent"))
        #expect(ApplicationVersionClient.source(for: pi, installation: installation("pi", .npm, "unrelated-package")) == nil)
        #expect(ApplicationVersionClient.source(for: kimi, installation: installation("kimi", .unknown, nil)) == nil)
        #expect(ApplicationVersionClient.source(for: kimi, installation: installation("pi", .native, nil)) == nil)
    }

    @Test func registryEndpointsAreHTTPSAndCannotEscapeTheirHost() throws {
        let npm = try ApplicationVersionClient.url(for: .npm("@openai/codex"))
        #expect(npm.absoluteString == "https://registry.npmjs.org/-/package/@openai%2Fcodex/dist-tags")
        let rejected: [ApplicationReleaseSource] = [
            .npm("https://example.test"), .npm("@scope/pkg?token=x"), .pypi("../../secret"),
            .github("owner/repo/extra"), .homebrew("../private", cask: true),
            .manifest("http://example.test/version.json"), .manifest("https://example.test/version.json")
        ]
        for source in rejected {
            #expect(throws: ApplicationVersionClient.Failure.invalidSource) {
                try ApplicationVersionClient.url(for: source)
            }
        }
    }

    @Test func parsesEachDeclaredRegistryFormat() throws {
        let cases: [(ApplicationReleaseSource, String, String)] = [
            (.npm("@openai/codex"), #"{"latest":"1.2.3","next":"2.0.0-beta.1"}"#, "1.2.3"),
            (.pypi("kimi-cli"), #"{"info":{"version":"0.80.1"}}"#, "0.80.1"),
            (.homebrew("cursor", cask: true), #"{"version":"3.2.1,abcdef"}"#, "3.2.1"),
            (.homebrew("gemini-cli", cask: false), #"{"versions":{"stable":"0.42.0"}}"#, "0.42.0"),
            (.manifest(ManagedApplicationCatalog.antigravityManifestURL), #"{"version":"1.5.2"}"#, "1.5.2"),
            (.github("NousResearch/hermes-agent"), #"{"tag_name":"v2026.8.31","name":"Hermes v0.21.0"}"#, "0.21.0")
        ]
        for (source, body, expected) in cases {
            #expect(try ApplicationVersionClient.version(in: Data(body.utf8), source: source) == expected)
        }
        #expect(throws: ApplicationVersionClient.Failure.missingVersion) {
            try ApplicationVersionClient.version(in: Data(#"{"tag_name":"v2026.8.31","name":"Release"}"#.utf8),
                                                 source: .github("NousResearch/hermes-agent"))
        }
    }

    @Test func requestsUseInjectedSessionAndPropagateHTTPFailures() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = ApplicationVersionClient(session: session)
        #expect(try await client.latest(for: .npm("fixture-success")) == "1.2.3")
        await #expect(throws: ApplicationVersionClient.Failure.httpStatus(429)) {
            try await client.latest(for: .npm("fixture-limited"))
        }
        await #expect(throws: ApplicationVersionClient.Failure.invalidResponse) {
            try await client.latest(for: .npm("fixture-invalid-json"))
        }
    }

    @Test func downloadLimitsRejectBothDeclaredAndStreamingOversizeResponses() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = ApplicationVersionClient(session: session)
        for package in ["fixture-large-header", "fixture-large-stream"] {
            await #expect(throws: ApplicationVersionClient.Failure.responseTooLarge) {
                try await client.latest(for: .npm(package))
            }
        }
    }

    private func installation(_ id: String, _ source: ApplicationInstallationSource,
                              _ package: String?) -> ApplicationInstallation {
        ApplicationInstallation(catalogID: id, path: "/test/bin/\(id)", resolvedPath: "/test/bin/\(id)",
                                source: source, package: package)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VersionResponseProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Responses depend only on the request, so parallel tests share no mutable fixtures.
private final class VersionResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let status = url.path.contains("fixture-limited") ? 429 : 200
        let headers = url.path.contains("fixture-large-header") ? ["Content-Length": "2097152"] : [:]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data: Data
        if url.path.contains("fixture-large-stream") {
            data = Data(repeating: 32, count: 1_048_577)
        } else if url.path.contains("fixture-invalid-json") {
            data = Data("<html>unavailable</html>".utf8)
        } else {
            data = Data(#"{"latest":"1.2.3"}"#.utf8)
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
