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
    /// Context the user has currently allocated for this model (when loaded).
    let loadedContextLength: Int?
    /// Publisher / organization, e.g. `"mlx-community"`, `"lmstudio-community"`.
    let publisher: String?
    /// File size on disk in bytes, from the `size` field of `/api/v0/models`.
    let sizeBytes: Int?
    /// When true, LM Studio will not evict this model from RAM when another is loaded.
    let keepInRam: Bool?

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
        case sizeBytes = "size"
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
        guard let bytes = sizeBytes, bytes > 0 else { return nil }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: mb >= 100 ? "%.0f MB" : "%.1f MB", mb)
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
    /// e.g. OpenRouter); otherwise a heuristic over the model id for LM Studio models.
    var supportsToolUse: Bool {
        if let toolUseSupported { return toolUseSupported }
        let lower = id.lowercased()
        let needles = [
            "hermes",           // Nous Hermes — function calling focus
            "functionary",
            "nexusraven",
            "gorilla",
            "xlam",             // Salesforce xLAM
            "hammer",
            "firefunction",
            "command-r",        // Cohere
            "toolbench",
            "fc-",              // function-calling variants
            "-fc",
            "qwen-coder",       // QwenCoder supports tool use
            "qwencoder",
        ]
        return needles.contains { lower.contains($0) }
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
