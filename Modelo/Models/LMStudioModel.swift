//
//  LMStudioModel.swift
//  Modelo
//
//  Created by Patrick Ruster on 5/14/26.
//

import Foundation

/// Represents a model from LM Studio — `/api/v0/models` populates the rich fields;
/// `/v1/models` only provides `id` and `object`. Not persisted.
struct LMStudioModel: Identifiable, Decodable, Hashable {
    let id: String
    /// API-reported object type. Embedding models report "embedding"; chat models report "model".
    let object: String?

    // MARK: Enhanced fields (/api/v0/models). Absent when falling back to /v1/models.

    /// `"llm"`, `"vlm"`, or `"embeddings"` from the LM Studio REST API.
    let type: String?
    /// Architecture family, e.g. `"qwen2"`, `"llama"`, `"gemma3"`.
    let arch: String?
    /// Quantization label, e.g. `"Q4_K_M"`, `"MLX 4bit"`.
    let quantization: String?
    /// `"loaded"`, `"not-loaded"`. nil means unknown.
    var state: String?
    /// Maximum context the model can hold.
    let maxContextLength: Int?
    /// Publisher / organization, e.g. `"mlx-community"`, `"lmstudio-community"`.
    let publisher: String?
    /// Context length the model is currently loaded with (`loaded_context_length`), when reported.
    let loadedContextLength: Int?
    /// File size on disk in bytes. LM Studio's `/api/v0/models` reports this as `size_bytes`;
    /// some OpenAI-compatible backends (llama-swap, MLX) use `size`. Decode whichever is present
    /// and read through `fileSizeBytes`.
    let sizeBytes: Int?
    /// Legacy `size` field, used as a fallback when `size_bytes` is absent.
    let sizeBytesAlt: Int?
    /// File size preferring the canonical `size_bytes`, falling back to the legacy `size`.
    var fileSizeBytes: Int? { sizeBytes ?? sizeBytesAlt }
    /// When true, LM Studio will not evict this model from RAM when another is loaded.
    var keepInRam: Bool?

    /// Zero-cost to use. Only meaningful for OpenRouter models (set from the
    /// API's pricing data when mapped); local models default to false and the
    /// UI never shows the flag for them. Not part of the LM Studio wire format.
    var isFree: Bool = false

    /// Authoritative tool-use flag from a provider that reports it (OpenRouter's
    /// `supported_parameters`). When nil (LM Studio), fall back to the id heuristic.
    /// Not part of the LM Studio wire format.
    var toolUseSupported: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case id, object, type, arch, quantization, state, publisher
        case maxContextLength = "max_context_length"
        case loadedContextLength = "loaded_context_length"
        case sizeBytes = "size_bytes"
        case sizeBytesAlt = "size"
        case keepInRam = "keep_in_ram"
    }

    // MARK: Derived

    var isEmbeddingModel: Bool {
        // When the v0 API provides a type, trust it exclusively — name heuristics
        // produce false positives (e.g. qwen3-embedding-4b-dwq has type "llm").
        if let type { return type.hasPrefix("embed") }
        if let obj = object, obj == "embedding" { return true }
        return id.lowercased().contains("embed")
    }

    var isLoaded: Bool { state == "loaded" }

    /// Authoritative when `type` is known; falls back to heuristic for /v1/models.
    var supportsVision: Bool {
        if let type { return type == "vlm" }
        return Self.supportsVision(modelID: id)
    }

    /// Strip publisher prefix when present; LM Studio echoes `org/model` in `id`.
    var shortName: String {
        if let slash = id.firstIndex(of: "/") { return String(id[id.index(after: slash)...]) }
        return id
    }

    /// The provider / organization prefix in OpenRouter IDs (`org/model` format).
    /// Returns nil for LM Studio IDs that have no slash.
    var providerID: String? {
        guard let slash = id.firstIndex(of: "/") else { return nil }
        return String(id[id.startIndex..<slash])
    }

    /// Unified family grouping key for filter pills.
    /// OpenRouter models use the provider prefix (e.g. `"anthropic"`, `"openai"`);
    /// local LM Studio models fall back to architecture family (e.g. `"llama"`, `"qwen"`).
    var familyTag: String? {
        if let p = providerID { return p }
        return displayArch
    }

    /// Back-compat alias used elsewhere in the app (e.g. the model-switcher menu).
    var displayName: String { id }

    /// Human family name — strips size, quant, format, and role suffixes that are
    /// already surfaced in the metric strip. Falls back to `shortName` when filtering
    /// would leave nothing meaningful.
    /// Examples:
    ///   `mlx-community/Qwen2.5-VL-7B-Instruct-4bit` → `Qwen2.5-VL`
    ///   `lmstudio-community/Meta-Llama-3.1-8B-Instruct-GGUF` → `Meta-Llama-3.1`
    ///   `bartowski/gemma-3-27b-it-GGUF` → `gemma-3`
    ///   `phi-3-mini-4k-instruct-q4_k_m` → `phi-3-mini`
    var familyName: String {
        let tokens = shortName.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        let kept = tokens.filter { !Self.isVariantToken($0) }
        guard !kept.isEmpty else { return shortName }
        return kept.joined(separator: "-")
    }

    /// True for tokens that describe quant/format/size/role rather than identity.
    private static func isVariantToken(_ raw: String) -> Bool {
        let t = raw.lowercased()
        if t.isEmpty { return false }

        // Size: 7b, 7.5b, 70b, 1.5b, 350m
        if matchesNumericSuffix(t, suffix: "b") { return true }
        if matchesNumericSuffix(t, suffix: "m") { return true }
        // Bit width: 4bit, 8bit, 16bit
        if t.hasSuffix("bit"), Int(t.dropLast(3)) != nil { return true }
        // MoE size shorthand: 8x7b, 2x22b
        if t.contains("x"), t.hasSuffix("b") {
            let parts = t.dropLast().split(separator: "x")
            if parts.count == 2, parts.allSatisfy({ Double($0) != nil }) { return true }
        }
        // Active-parameters tag: a3b, a22b
        if t.hasPrefix("a"), matchesNumericSuffix(String(t.dropFirst()), suffix: "b") { return true }
        // Context shorthand: 4k, 128k, 1m
        if t.hasSuffix("k"), Double(t.dropLast()) != nil { return true }
        // Quantization labels — bare or with grouping suffixes
        let quantPrefixes = ["q", "iq", "fp", "bf"]
        for prefix in quantPrefixes where t.hasPrefix(prefix) {
            let rest = t.dropFirst(prefix.count)
            if let first = rest.first, first.isNumber { return true }
        }
        // Containers and quant systems
        let exact: Set<String> = [
            "gguf", "ggml", "mlx", "awq", "gptq", "exl2", "exl3", "safetensors",
            "instruct", "it", "chat", "base", "sft", "dpo", "rlhf",
            "tuned", "finetune", "finetuned", "uncensored",
            "preview", "experimental", "alpha", "beta", "rc",
        ]
        return exact.contains(t)
    }

    /// `"7b"`, `"1.5b"` → true; `"qwen2.5"` → false; `"b"` alone → false.
    private static func matchesNumericSuffix(_ token: String, suffix: Character) -> Bool {
        guard token.last == suffix, token.count > 1 else { return false }
        return Double(token.dropLast()) != nil
    }

    /// Best-effort parameter size, e.g. `"7B"`, `"70B"`. nil when not embedded in the id.
    /// Walks the id looking for `<number>B` not immediately followed by a letter.
    var parameterSize: String? {
        let chars = Array(id)
        var i = 0
        while i < chars.count {
            if chars[i].isNumber {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                if j < chars.count, chars[j] == "b" || chars[j] == "B" {
                    let next = j + 1
                    if next >= chars.count || !chars[next].isLetter {
                        return String(chars[i..<j]) + "B"
                    }
                }
                i = j
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Human-readable file size, e.g. `"4.2 GB"`, `"512 MB"`. nil when unknown.
    var fileSizeFormatted: String? {
        guard let bytes = fileSizeBytes, bytes > 0 else { return nil }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: mb >= 100 ? "%.0f MB" : "%.1f MB", mb)
    }

    /// True for mixture-of-experts models (e.g. Mixtral 8x7B, Llama 4 Scout 17B-16E).
    /// MoE IDs embed the *active* parameter count, not total weight — estimating
    /// size from active params produces a number that's 4–8× too small.
    private var isMixtureOfExperts: Bool {
        let lower = id.lowercased()
        // Sparse-expert shorthand: "8x7b", "2x22b"
        if lower.range(of: #"\d+x\d+[bm]"#, options: .regularExpression) != nil { return true }
        // Expert-count suffix after a separator: "-16e-", "-16e" at end of segment
        if lower.range(of: #"[-_]\d+e(?:[-_]|$)"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Best-effort human-readable size: exact API value when available, otherwise
    /// estimated from parameter count × quantization bit-depth (prefixed with `~`).
    /// Returns nil when neither source provides enough information, or when the model
    /// is a mixture-of-experts (active-param estimates are off by 4–8× for MoE).
    var displaySizeFormatted: String? {
        if let exact = fileSizeFormatted { return exact }

        // MoE models list active-parameter counts in their IDs, not total weight.
        // The estimation below would show e.g. ~8.7 GB for a model that actually
        // needs 70+ GB in RAM — suppress it rather than show a misleading number.
        if isMixtureOfExperts { return nil }
        // Parse parameter count from id (e.g. "30B" → 30 × 10⁹).
        guard let paramStr = parameterSize else { return nil }
        let upper = paramStr.uppercased()
        let scale: Double
        let digits: String
        if upper.hasSuffix("B") {
            scale = 1_000_000_000; digits = String(upper.dropLast())
        } else if upper.hasSuffix("M") {
            scale = 1_000_000; digits = String(upper.dropLast())
        } else { return nil }
        guard let paramCount = Double(digits), paramCount > 0 else { return nil }
        let params = paramCount * scale

        // Parse bit-depth from quantization. Handles "4bit", "Q4_K_M", "f16", etc.
        let q = (quantization ?? "").lowercased()
        let bits: Double
        if      q.contains("2bit") || q.hasPrefix("q2") || q == "int2" { bits = 2 }
        else if q.contains("3bit") || q.hasPrefix("q3")                { bits = 3 }
        else if q.contains("4bit") || q.hasPrefix("q4") || q == "int4" { bits = 4 }
        else if q.contains("5bit") || q.hasPrefix("q5")                { bits = 5 }
        else if q.contains("6bit") || q.hasPrefix("q6")                { bits = 6 }
        else if q.contains("8bit") || q.hasPrefix("q8") || q == "int8" { bits = 8 }
        else if q.contains("f16") || q == "float16" || q == "fp16"     { bits = 16 }
        else if q.contains("f32") || q == "float32" || q == "fp32"     { bits = 32 }
        else { return nil }

        // ~10% overhead for non-quantized layers, buffers, and metadata.
        let bytes = params * bits / 8.0 * 1.10
        let gb = bytes / 1_073_741_824
        if gb >= 10 { return "~\(Int(gb.rounded())) GB" }
        if gb >= 1  { return String(format: "~%.1f GB", gb) }
        let mb = bytes / 1_048_576
        return String(format: "~%.0f MB", mb)
    }

    /// Display arch — prefers API field, falls back to a rough id-derived guess.
    var displayArch: String? {
        if let arch { return arch }
        let lower = id.lowercased()
        for needle in ["qwen", "llama", "gemma", "mistral", "phi", "deepseek", "pixtral", "llava", "moondream"] {
            if lower.contains(needle) { return needle }
        }
        return nil
    }

    /// Heuristic thinking/reasoning detection — models that emit <think> blocks.
    var supportsThinking: Bool {
        let lower = id.lowercased()
        let needles = [
            "deepseek-r",       // r1, r1.5, r2
            "qwq",
            "qwen3",            // thinking mode enabled by default
            "skywork-o",
            "phi-4-reasoning",
            "granite-reasoning",
            "o1-",              // local o1 fine-tunes
            "-o1",
            "thinking",
            "reasoning",
        ]
        return needles.contains { lower.contains($0) }
    }

    /// Tool-use support. Authoritative when a provider reports it (`toolUseSupported`,
    /// e.g. OpenRouter). For LM Studio models, we default to `true` for most modern
    /// models because LM Studio's OpenAI-compatible API enables tool use across the
    /// board; we only return `false` for embeddings and base/pretrained variants.
    var supportsToolUse: Bool {
        if let toolUseSupported { return toolUseSupported }

        let lower = id.lowercased()

        // Embedding models never support chat tools.
        if isEmbeddingModel { return false }

        // Base/pretrained variants are the clearest signal of no tool support.
        let baseIndicators = [
            "base", "pretrained", "raw-base", "foundation",
        ]
        if baseIndicators.contains(where: { lower.contains($0) }) { return false }

        return true
    }

    /// Heuristic vision detection — used when `type` is absent (/v1/models fallback).
    static func supportsVision(modelID: String) -> Bool {
        let id = modelID.lowercased()
        let needles = [
            "-vl",          // qwen-vl, qwen2.5-vl
            "vision",       // phi-3-vision, ovis-vision
            "llava",
            "gemma-3", "gemma3",
            "pixtral",
            "moondream",
            "internvl",
            "minicpm-v", "minicpm-o",
            "idefics",
            "molmo",
            "cogvlm",
            "bakllava",
            "llama-3.2-11b", "llama-3.2-90b",   // vision variants
            "mistral-small-3.1",
        ]
        return needles.contains { id.contains($0) }
    }
}

struct ModelsResponse: Decodable {
    let data: [LMStudioModel]
}
