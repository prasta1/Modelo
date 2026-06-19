import Foundation

/// Fetch a single URL as markdown.
struct FirecrawlScrapeTool: Tool {
    let name = "firecrawl_scrape"
    let description = "Fetch a web page by URL and return its content as clean markdown."
    let parameters = JSONSchema(
        properties: ["url": .init("string", "The absolute URL to fetch")],
        required: ["url"])
    let client: FirecrawlClient

    func execute(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let url: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        return try await client.scrape(url: args.url)
    }
}

/// Search the web and return the top results.
struct FirecrawlSearchTool: Tool {
    let name = "firecrawl_search"
    let description = "Search the web and return the top results (title, URL, snippet)."
    let parameters = JSONSchema(
        properties: [
            "query": .init("string", "The search query"),
            "limit": .init("integer", "Maximum number of results (default 5)")
        ],
        required: ["query"])
    let client: FirecrawlClient

    func execute(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let query: String; let limit: Int? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        return try await client.search(query: args.query, limit: args.limit ?? 5)
    }
}
