import Foundation

/// Minimal client for Firecrawl's v1 API (scrape + search). Bearer auth; the
/// `URLSession` is injected so tests stub the network. Reuses `ClientError`.
final class FirecrawlClient: Sendable {
    /// Keychain account holding the key (account-level: one key for the app).
    static let keychainAccount = "firecrawl"

    private let apiKey: String
    private let session: URLSession
    private let base = "https://api.firecrawl.dev/v1"

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Fetches a page and returns its content as markdown.
    func scrape(url: String) async throws -> String {
        let data = try await post(path: "/scrape", body: ScrapeRequest(url: url, formats: ["markdown"]))
        let decoded = try JSONDecoder().decode(ScrapeResponse.self, from: data)
        guard let md = decoded.data?.markdown, !md.isEmpty else {
            throw ClientError.serverError("Firecrawl returned no content for \(url).")
        }
        return md
    }

    /// Web search; returns a compact markdown list of results.
    func search(query: String, limit: Int) async throws -> String {
        let data = try await post(path: "/search", body: SearchRequest(query: query, limit: limit))
        let results = (try JSONDecoder().decode(SearchResponse.self, from: data)).data ?? []
        guard !results.isEmpty else { return "No results for \"\(query)\"." }
        return results.map { r in
            "- \(r.title ?? r.url ?? "untitled")\n  \(r.url ?? "")\n  \(r.description ?? "")"
        }.joined(separator: "\n")
    }

    private func post<B: Encodable>(path: String, body: B) async throws -> Data {
        guard let url = URL(string: base + path) else { throw ClientError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.serverError("Firecrawl request failed.")
        }
        return data
    }

    // MARK: Wire types (Firecrawl v1)
    private struct ScrapeRequest: Encodable { let url: String; let formats: [String] }
    private struct ScrapeResponse: Decodable {
        let data: Page?
        struct Page: Decodable { let markdown: String? }
    }
    private struct SearchRequest: Encodable { let query: String; let limit: Int }
    private struct SearchResponse: Decodable {
        let data: [Result]?
        struct Result: Decodable { let url: String?; let title: String?; let description: String? }
    }
}
