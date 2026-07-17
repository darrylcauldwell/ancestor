import Foundation

/// Phase 3 of the lead-discovery pivot (`AncestorApp/LEAD_DISCOVERY_SPEC.md`).
///
/// The text→vector contract the fuzzy-bridge runs on, plus the always-available
/// deterministic implementation. Real MLX semantic embeddings (when a model is
/// loaded) plug in behind the same `[Float]` contract via `MLXTextEmbedder`;
/// this deterministic embedder is the fallback so the bridge — and the whole
/// app — is fully functional with no model, per the app's deterministic-first
/// principle.
nonisolated protocol TextEmbedder: Sendable {
    /// Embed each text into a fixed-length, L2-normalised vector. Same length
    /// for every text from a given embedder.
    func embed(_ texts: [String]) async -> [[Float]]
}

/// A hashed character-trigram term-frequency vector, L2-normalised. Fully
/// deterministic and reproducible (no model, no randomness), so two runs — and
/// two machines — cluster identically. It captures spelling overlap, which is
/// exactly the fuzzy signal the exact-surname block key misses
/// ("CAULDWELL"/"COLDWELL" share most trigrams).
nonisolated struct DeterministicTextEmbedder: TextEmbedder {
    let dimension: Int

    init(dimension: Int = 256) { self.dimension = dimension }

    func embed(_ texts: [String]) async -> [[Float]] {
        texts.map { Self.vector(for: $0, dimension: dimension) }
    }

    static func vector(for text: String, dimension: Int = 256) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        // Pad so leading/trailing trigrams are represented; letters + spaces only.
        let cleaned = text.lowercased().map { ($0.isLetter || $0 == " ") ? $0 : " " }
        let chars = Array("  " + String(cleaned) + "  ")
        guard chars.count >= 3 else { return v }
        for i in 0...(chars.count - 3) {
            let tri = String(chars[i ... i + 2])
            let idx = Self.stableHash(tri) % dimension
            v[idx] += 1
        }
        let norm = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// djb2 — stable across processes (Swift's `Hasher` is per-process seeded,
    /// which would make embeddings non-reproducible). Non-negative result.
    static func stableHash(_ s: String) -> Int {
        var h = 5381
        for b in s.utf8 { h = (h &* 33) &+ Int(b) }
        return h & 0x7fff_ffff
    }
}

/// Cosine similarity of two L2-normalised vectors (a plain dot product, since
/// both are unit-length). Deterministic math over whatever produced the
/// vectors — this is the "AI proposes, deterministic math decides" boundary:
/// the embedder may be a model, but the comparison never is.
nonisolated enum VectorMath {
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        for i in a.indices { dot += Double(a[i]) * Double(b[i]) }
        return dot
    }
}
