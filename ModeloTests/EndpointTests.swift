import XCTest
import SwiftData
@testable import Modelo

final class EndpointTests: XCTestCase {
    func test_baseURL_lmStudio() {
        let s = Server(label: "Studio", host: "studio", port: 1234)
        XCTAssertEqual(s.kind, .lmStudio)
        XCTAssertEqual(s.baseURL, "http://studio:1234")
    }

    func test_baseURL_openRouter_ignoresHostPort() {
        let s = Server(label: "OpenRouter", host: "", port: 0, kind: .openRouter)
        XCTAssertEqual(s.kind, .openRouter)
        XCTAssertEqual(s.baseURL, "https://openrouter.ai/api/v1")
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
    func test_endpoint_fromOpenRouterServer_readsKeyFromKeychain() {
        let s = Server(label: "OpenRouter", host: "", port: 0, kind: .openRouter)
        let kc = KeychainStore(service: "com.peregrine.modelo.tests.\(UUID().uuidString)")
        kc.set("sk-or-123", account: "openrouter:\(s.id)")
        let ep = Endpoint(server: s, keychain: kc)
        XCTAssertEqual(ep.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(ep.kind, .openRouter)
        XCTAssertEqual(ep.apiKey, "sk-or-123")
    }
}
