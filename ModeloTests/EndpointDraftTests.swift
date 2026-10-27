import XCTest
import SwiftData
@testable import Modelo

@MainActor
final class EndpointDraftTests: XCTestCase {
    private var context: ModelContext!
    private var keychain: KeychainStore!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: StoreBootstrap.schema, configurations: [config])
        context = ModelContext(container)
        // Unique service per test so we never touch real app keys.
        keychain = KeychainStore(service: "com.peregrine.modelo.tests.\(UUID().uuidString)")
    }

    private func servers() throws -> [Server] {
        try context.fetch(FetchDescriptor<Server>(sortBy: [SortDescriptor(\.sortOrder)]))
    }

    private func local(_ host: String, port: Int = 1234) -> EndpointDraft {
        var d = EndpointDraft(kind: .lmStudio)
        d.host = host
        d.port = port
        return d
    }

    // MARK: - New drafts and runtime switching

    func test_newLocal_prefillsDefaults() {
        let d = EndpointDraft(kind: .ollama)
        XCTAssertEqual(d.port, 11434)
        XCTAssertEqual(d.label, "Ollama")
        XCTAssertEqual(d.host, "")
    }

    func test_switchRuntime_reseedsDefaultPortAndLabel() {
        var d = EndpointDraft(kind: .lmStudio)
        d.switchRuntime(to: .ollama)
        XCTAssertEqual(d.kind, .ollama)
        XCTAssertEqual(d.port, 11434)
        XCTAssertEqual(d.label, "Ollama")
    }

    func test_switchRuntime_keepsCustomPortAndLabel() {
        var d = EndpointDraft(kind: .lmStudio)
        d.port = 9999
        d.label = "Spark"
        d.switchRuntime(to: .ollama)
        XCTAssertEqual(d.port, 9999)
        XCTAssertEqual(d.label, "Spark")
    }

    // MARK: - Validation

    func test_isValid_local() {
        XCTAssertFalse(local("  ").isValid)
        XCTAssertFalse(local("http://").isValid)
        XCTAssertFalse(local("https://").isValid)
        XCTAssertTrue(local("spark").isValid)
        XCTAssertFalse(local("spark", port: 0).isValid)
        XCTAssertFalse(local("spark", port: 70000).isValid)
        var blankLabel = local("spark")
        blankLabel.label = " "
        XCTAssertFalse(blankLabel.isValid)
    }

    func test_isValid_customCloud() {
        var d = EndpointDraft(kind: .cloudAPI)
        d.host = "api.example.com"
        XCTAssertFalse(d.isValid)
        d.host = "https://api.example.com/v1"
        XCTAssertTrue(d.isValid)
    }

    func test_isValid_fixedURLKinds() {
        XCTAssertTrue(EndpointDraft(kind: .openRouter).isValid)
        XCTAssertTrue(EndpointDraft(kind: .nous).isValid)
    }

    // MARK: - Save

    func test_save_insertsWithNextSortOrder() throws {
        let first = local("a").save(into: context, keychain: keychain, existing: nil)
        XCTAssertEqual(first.sortOrder, 1)
        first.sortOrder = 3
        let next = local("b").save(into: context, keychain: keychain, existing: nil)
        XCTAssertEqual(next.sortOrder, 4)
    }

    func test_save_normalizesHost() {
        XCTAssertEqual(local("http://spark/").save(into: context, keychain: keychain, existing: nil).host, "spark")
        XCTAssertEqual(local("  spark ").save(into: context, keychain: keychain, existing: nil).host, "spark")
    }

    func test_save_keepsHTTPSPrefix() {
        let s = local("https://box.ts.net").save(into: context, keychain: keychain, existing: nil)
        XCTAssertEqual(s.host, "https://box.ts.net")
    }

    func test_save_cloud_storesTrimmedKeyInKeychainOnly() {
        var d = EndpointDraft(kind: .openRouter)
        d.apiKey = "  sk-1 "
        let s = d.save(into: context, keychain: keychain, existing: nil)
        XCTAssertEqual(keychain.get(account: Endpoint.keychainAccount(for: s)), "sk-1")
        XCTAssertNil(s.apiKey)
    }

    func test_save_cloud_emptyKeyClearsKeychain() {
        var d = EndpointDraft(kind: .openRouter)
        d.apiKey = "old"
        let s = d.save(into: context, keychain: keychain, existing: nil)
        d.apiKey = ""
        d.save(into: context, keychain: keychain, existing: s)
        XCTAssertNil(keychain.get(account: Endpoint.keychainAccount(for: s)))
    }

    func test_save_existing_updatesInPlace() throws {
        var d = local("spark")
        let s = d.save(into: context, keychain: keychain, existing: nil)
        d.label = "Renamed"
        d.save(into: context, keychain: keychain, existing: s)
        let all = try servers()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.label, "Renamed")
    }

    func test_initFromServer_roundTrips() {
        var d = EndpointDraft(preset: CloudPreset.all[0])
        d.apiKey = " sk-2 "
        d.label = " OpenAI work "
        let s = d.save(into: context, keychain: keychain, existing: nil)
        let back = EndpointDraft(server: s, keychain: keychain)
        XCTAssertEqual(back.kind, .cloudAPI)
        XCTAssertEqual(back.label, "OpenAI work")
        XCTAssertEqual(back.host, CloudPreset.all[0].baseURL)
        XCTAssertEqual(back.apiKey, "sk-2")
    }

    func test_endpoint_usesNormalizedBaseURL() {
        let e = local("http://spark").endpoint
        XCTAssertEqual(e.baseURL, "http://spark:1234")
        XCTAssertNil(e.apiKey)
    }

    // MARK: - Delete and reorder

    func test_delete_removesServerAndKeychainSecret() throws {
        var d = EndpointDraft(kind: .openRouter)
        d.apiKey = "sk-3"
        let s = d.save(into: context, keychain: keychain, existing: nil)
        let account = Endpoint.keychainAccount(for: s)
        ServerListActions.delete(s, in: context, keychain: keychain)
        XCTAssertEqual(try servers().count, 0)
        XCTAssertNil(keychain.get(account: account))
    }

    func test_reorder_rewritesSortOrderContiguously() {
        let a = Server(label: "A", host: "a", sortOrder: 5)
        let b = Server(label: "B", host: "b", sortOrder: 9)
        let c = Server(label: "C", host: "c", sortOrder: 12)
        [a, b, c].forEach(context.insert)
        ServerListActions.reorder([a, b, c], fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual([c.sortOrder, a.sortOrder, b.sortOrder], [0, 1, 2])
    }
}
