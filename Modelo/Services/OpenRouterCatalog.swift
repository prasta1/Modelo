import Foundation

/// Pure decode of OpenRouter's `/models` response and mapping into the app's
/// existing `LMStudioModel`, so the picker/tags/context-bar work unchanged.
enum OpenRouterCatalog {
    /// Decodes the response, mapping each well-formed entry. Malformed entries
    /// (e.g. missing `id`) are skipped rather than failing the whole catalog.
    static func models(from data: Data) throws -> [LMStudioModel] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var models = response.data.compactMap(map)
        // A `:free` promo variant shows what the paid version normally costs.
        let paid = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for i in models.indices where models[i].id.hasSuffix(":free") {
            guard let sibling = paid[String(models[i].id.dropLast(":free".count))] else { continue }
            models[i].normalInputPricePerM = sibling.inputPricePerM
            models[i].normalOutputPricePerM = sibling.outputPricePerM
        }
        return models
    }

    /// Per-token USD string ("0.0000002500") → USD per million tokens.
    private static func perMillion(_ s: String?) -> Double? {
        s.flatMap(Double.init).map { $0 * 1_000_000 }
    }

    private static func map(_ e: Entry) -> LMStudioModel? {
        guard let id = e.id, !id.isEmpty else { return nil }
        let input = perMillion(e.pricing?.prompt)
        let output = perMillion(e.pricing?.completion)
        // Numeric compare: Nous writes zero as "0.0000000000", not "0".
        let free = (input == 0 && output == 0) || id.hasSuffix(":free")
        let tools = e.supported_parameters?.contains("tools") ?? false
        let vision = e.architecture?.input_modalities?.contains("image") ?? false
        // `output_modalities == ["embeddings"]` is the authoritative embedding
        // signal, and `type` must carry it: LMStudioModel.isEmbeddingModel trusts
        // `type` exclusively when set, so anything else here silently disables the
        // embedding filter at every call site. It also beats the id heuristic the
        // nil-type path falls back to — that misses bge/e5-style names entirely.
        let isEmbedding = e.architecture?.output_modalities == ["embeddings"]
        var model = LMStudioModel(
            id: id, object: "model",
            type: isEmbedding ? "embeddings" : (vision ? "vlm" : "llm"),
            arch: nil, quantization: nil, state: nil,
            maxContextLength: e.context_length,
            publisher: nil,
            loadedContextLength: nil, sizeBytes: nil, sizeBytesAlt: nil,
            keepInRam: nil, isFree: free, toolUseSupported: tools
        )
        model.inputPricePerM = input
        model.outputPricePerM = output
        if free { model.freeUntil = e.expiration_date.flatMap(dayFormatter.date(from:)) }
        return model
    }

    /// `expiration_date` is a bare day ("2026-10-31"), read as UTC midnight.
    private static let dayFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    // MARK: Wire types (OpenRouter `/models`)
    private struct Response: Decodable { let data: [Entry] }
    private struct Entry: Decodable {
        let id: String?
        let context_length: Int?
        let pricing: Pricing?
        let architecture: Architecture?
        let supported_parameters: [String]?
        let expiration_date: String?
    }
    private struct Pricing: Decodable { let prompt: String?; let completion: String? }
    private struct Architecture: Decodable {
        let input_modalities: [String]?
        let output_modalities: [String]?
    }
}
