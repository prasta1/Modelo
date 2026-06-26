import Foundation

/// Pure decode of OpenRouter's `/models` response and mapping into the app's
/// existing `LMStudioModel`, so the picker/tags/context-bar work unchanged.
enum OpenRouterCatalog {
    /// Decodes the response, mapping each well-formed entry. Malformed entries
    /// (e.g. missing `id`) are skipped rather than failing the whole catalog.
    static func models(from data: Data) throws -> [LMStudioModel] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.data.compactMap(map)
    }

    private static func map(_ e: Entry) -> LMStudioModel? {
        guard let id = e.id, !id.isEmpty else { return nil }
        let free = (e.pricing?.prompt == "0" && e.pricing?.completion == "0")
            || id.hasSuffix(":free")
        let tools = e.supported_parameters?.contains("tools") ?? false
        let vision = e.architecture?.input_modalities?.contains("image") ?? false
        return LMStudioModel(
            id: id, object: "model",
            type: vision ? "vlm" : "llm",
            arch: nil, quantization: nil, state: nil,
            maxContextLength: e.context_length,
            publisher: nil,
            loadedContextLength: nil, sizeBytes: nil, sizeBytesAlt: nil,
            keepInRam: nil, isFree: free, toolUseSupported: tools
        )
    }

    // MARK: Wire types (OpenRouter `/models`)
    private struct Response: Decodable { let data: [Entry] }
    private struct Entry: Decodable {
        let id: String?
        let context_length: Int?
        let pricing: Pricing?
        let architecture: Architecture?
        let supported_parameters: [String]?
    }
    private struct Pricing: Decodable { let prompt: String?; let completion: String? }
    private struct Architecture: Decodable { let input_modalities: [String]? }
}
