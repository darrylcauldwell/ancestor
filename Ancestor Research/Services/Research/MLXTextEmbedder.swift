import Foundation

// Phase 3 real-embedding leg (LEAD_DISCOVERY_SPEC). Compiles only when both the
// MLXEmbedders product AND the underlying MLX product are linked to this target.
// Until then the app uses `DeterministicTextEmbedder` and everything works.
#if canImport(MLXEmbedders) && canImport(MLX)

import os
import MLX
import MLXEmbedders
import MLXLMCommon
import Tokenizers

/// Real MLX semantic embeddings for the discovery fuzzy-bridge. Loads a small
/// sentence-embedding model and produces L2-normalised vectors behind the same
/// `TextEmbedder` contract as `DeterministicTextEmbedder`. Actor-isolated; when
/// no model is loaded `embed` returns `[]`, and callers fall back to the
/// deterministic embedder — so the app stays fully functional with no model.
///
/// This is the "AI proposes" half only: the vectors feed
/// `LeadDiscoveryEngine.bridgeVariantSurnames`, whose deterministic gates make
/// every merge decision. Cosine similarity over these vectors is plain math.
actor MLXTextEmbedder: TextEmbedder {
    static let shared = MLXTextEmbedder()

    /// Small, fast English sentence-embedding model — enough to tell name/place
    /// texts apart without a multi-GB download.
    static let defaultConfiguration = EmbedderRegistry.minilm_l6

    private var container: EmbedderModelContainer?
    private var loadingTask: Task<EmbedderModelContainer, Error>?
    private let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research", category: "MLXTextEmbedder")

    var isAvailable: Bool { container != nil }

    /// Load (once) the embedding model. Safe to call repeatedly; concurrent
    /// callers share one in-flight load.
    func loadModel(configuration: ModelConfiguration = MLXTextEmbedder.defaultConfiguration) async throws {
        if container != nil { return }
        if let task = loadingTask { _ = try await task.value; return }
        let task = Task<EmbedderModelContainer, Error> {
            try await EmbedderModelFactory.shared.loadContainer(
                from: HuggingFaceDownloader(),
                using: TransformersTokenizerLoader(),
                configuration: configuration
            ) { _ in }
        }
        loadingTask = task
        do {
            container = try await task.value
            loadingTask = nil
            logger.info("Embedding model loaded: \(configuration.name)")
        } catch {
            loadingTask = nil
            logger.error("Failed to load embedding model: \(error.localizedDescription)")
            throw error
        }
    }

    func embed(_ texts: [String]) async -> [[Float]] {
        guard let container, !texts.isEmpty else { return [] }
        return await container.perform { (ctx: EmbedderModelContext) -> [[Float]] in
            let model = ctx.model
            let tokenizer = ctx.tokenizer
            let pooling = ctx.pooling
            let inputs = texts.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
            let padTo = inputs.reduce(into: 16) { $0 = max($0, $1.count) }
            let eos = tokenizer.eosTokenId ?? 0
            let padded = stacked(
                inputs.map { row in
                    MLXArray(row + Array(repeating: eos, count: padTo - row.count))
                })
            let mask = padded .!= eos
            let tokenTypes = MLXArray.zeros(like: padded)
            let pooled = pooling(
                model(padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask),
                normalize: true, applyLayerNorm: true
            )
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
    }
}

#elseif canImport(MLXEmbedders)
#warning("MLXTextEmbedder: MLXEmbedders is linked but the MLX module is not importable — add the mlx-swift package's MLX product to the Ancestor Research target to enable real semantic embeddings. The deterministic embedder remains in use until then.")
#endif
