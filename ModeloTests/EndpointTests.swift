import XCTest
import SwiftData
@testable import Modelo

final class EndpointTests: XCTestCase {
    func test_baseURL_lmStudio() {
        let s = Server(label: "Studio", host: "studio", port: 1234)
        XCTAssertEqual(s.kind, .lmStudio)
        XCTAssertEqual(s.baseURL, "http://studio:1234")
    }

    func test_baseURL_cloudAPI_usesHostFieldAsURL() {
        let s = Server(label: "Together", host: "https://api.together.xyz/v1", port: 0, kind: .cloudAPI)
        XCTAssertEqual(s.kind, .cloudAPI)
        XCTAssertEqual(s.baseURL, "https://api.together.xyz/v1")
    }

    // MARK: - ServerKind (rename back-compat + new oMLX runtime)

    /// Servers saved before the `llamaSwap` → `llamaCpp` rename persisted the raw
    /// string "llamaSwap"; they must still decode to the renamed case.
    func test_serverKind_llamaSwapRawValue_decodesToLlamaCpp() {
        XCTAssertEqual(ServerKind(rawValue: "llamaSwap"), .llamaCpp)
        XCTAssertEqual(ServerKind.llamaCpp.rawValue, "llamaSwap")
    }

    /// The cloud cases keep their historically-inverted raw values for back-compat.
    func test_serverKind_cloudRawValues_unchanged() {
        XCTAssertEqual(ServerKind.cloudAPI.rawValue, "openRouter")
        XCTAssertEqual(ServerKind.openRouter.rawValue, "openRouterFixed")
    }

    func test_serverKind_localCases_areThreeRuntimes() {
        XCTAssertEqual(ServerKind.localCases, [.lmStudio, .llamaCpp, .oMLX])
        XCTAssertTrue(ServerKind.oMLX.isLocal)
        XCTAssertFalse(ServerKind.cloudAPI.isLocal)
    }

    func test_baseURL_oMLX_usesHostPort() {
        let s = Server(label: "oMLX", host: "mac-studio", port: 8000, kind: .oMLX)
        XCTAssertEqual(s.baseURL, "http://mac-studio:8000")
    }

    func test_serverKind_defaultPorts() {
        XCTAssertEqual(ServerKind.oMLX.defaultPort, 8000)
        XCTAssertEqual(ServerKind.llamaCpp.defaultPort, 8080)
        XCTAssertTrue(ServerKind.isDefaultLocalPort(8000))
        XCTAssertFalse(ServerKind.isDefaultLocalPort(31337))
    }

    // MARK: - Host normalization (regression: doubled-up scheme made the probe fail)

    func test_baseURL_stripsHttpScheme() {
        let s = Server(label: "MacBook", host: "http://localhost", port: 1234)
        XCTAssertEqual(s.baseURL, "http://localhost:1234")
    }

    func test_baseURL_stripsHttpsScheme_alwaysHTTPForLMStudio() {
        let s = Server(label: "MacBook", host: "https://localhost", port: 1234)
        XCTAssertEqual(s.baseURL, "http://localhost:1234")
    }

    func test_baseURL_bareHost_unchanged() {
        let s = Server(label: "MacBook", host: "localhost", port: 1234)
        XCTAssertEqual(s.baseURL, "http://localhost:1234")
    }

    func test_baseURL_trimsWhitespaceAndTrailingSlash() {
        let s = Server(label: "MacBook", host: "  http://localhost/  ", port: 1234)
        XCTAssertEqual(s.baseURL, "http://localhost:1234")
    }

    func test_baseURL_stripsUppercaseScheme() {
        let s = Server(label: "MacBook", host: "HTTP://localhost", port: 1234)
        XCTAssertEqual(s.baseURL, "http://localhost:1234")
    }

    func test_baseURL_stripsMultipleTrailingSlashes() {
        let s = Server(label: "MacBook", host: "http://localhost///", port: 1234)
        XCTAssertEqual(s.baseURL, "http://localhost:1234")
    }

    // An empty (or scheme-only, which normalizes to empty) host has no valid URL
    // to form; documenting the by-design result so the contract is explicit.
    func test_baseURL_emptyHost_isHostless() {
        let s = Server(label: "MacBook", host: "http://", port: 1234)
        XCTAssertEqual(s.baseURL, "http://:1234")
    }

    func test_baseURL_withPath_yieldsNonNilURL() {
        let s = Server(label: "MacBook", host: "http://localhost", port: 1234)
        let url = URL(string: "\(s.baseURL)/api/v0/models")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "http://localhost:1234/api/v0/models")
    }

    @MainActor
    func test_endpoint_fromLMStudioServer_hasNoKey() {
        let s = Server(label: "Studio", host: "studio", port: 1234)
        let kc = KeychainStore(service: "com.peregrine.modelo.tests.\(UUID().uuidString)")
        let ep = Endpoint(server: s, keychain: kc)
        XCTAssertEqual(ep.baseURL, "http://studio:1234")
        XCTAssertEqual(ep.kind, .lmStudio)
        XCTAssertNil(ep.apiKey)
    }

    @MainActor
    func test_endpoint_fromCloudAPIServer_readsKeyFromKeychain() throws {
        // Server is a @Model — its `id` is only stable once inserted into a ModelContext.
        // Without a context, repeated accesses to `id` can return different UUIDs, causing
        // the keychain write and read to use mismatched account keys.
        let schema = Schema([Server.self, ModelContextOverride.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [config]))
        let s = Server(label: "Groq", host: "https://api.groq.com/openai/v1", port: 0, kind: .cloudAPI)
        context.insert(s)
        let kc = KeychainStore(service: "com.peregrine.modelo.tests.\(UUID().uuidString)")
        kc.set("gsk-123", account: Endpoint.keychainAccount(for: s))
        let ep = Endpoint(server: s, keychain: kc)
        XCTAssertEqual(ep.baseURL, "https://api.groq.com/openai/v1")
        XCTAssertEqual(ep.kind, .cloudAPI)
        XCTAssertEqual(ep.apiKey, "gsk-123")
    }
}
