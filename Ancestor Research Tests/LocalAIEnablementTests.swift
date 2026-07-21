import Testing
import Foundation
@testable import Ancestor_Research

/// PROJECT_ONBOARDING_SPEC Part A Step 2 (enable local AI). Step 2 is mostly a
/// consent UI + download wiring (not unit-tested per project convention), but
/// two things are load-bearing and testable: the embedder's on-disk folder
/// convention (if it's wrong, "auto-use once downloaded" silently never fires
/// because the presence check looks in the wrong place) and the display facts
/// the wizard copy reads.
struct LocalAIEnablementTests {

    /// The reasoning model's display facts the wizard shows — pinned so a
    /// change to the default or its size can't silently make the consent copy
    /// wrong.
    @Test func reasoningDefaultDisplayFactsStable() {
        let model = ReasoningModel.default
        #expect(model == .qwen35_4B)
        #expect(model.memoryEstimateGB == 4.0)
        #expect(!model.displayName.isEmpty)
        #expect(model.huggingFaceID == "mlx-community/Qwen3.5-4B-MLX-4bit")
    }

    #if canImport(MLXEmbedders) && canImport(MLX)

    /// The embedder must resolve to the same on-disk folder the MLX downloader
    /// writes into — "{appSupport}/{bundle}/models/{org--repo}". If this drifts
    /// from the reasoning model's convention, the launch auto-load's presence
    /// check reads an empty directory and never auto-uses the model.
    @Test func embedderOnDiskFolderConvention() {
        let dir = MLXTextEmbedder.shared.sandboxModelDirectory()
        #expect(dir != nil)
        #expect(dir?.lastPathComponent == "sentence-transformers--all-MiniLM-L6-v2")
        #expect(dir?.deletingLastPathComponent().lastPathComponent == "models")
    }

    /// Presence check is consistent and safe when the model is absent (the
    /// common test-machine state): non-negative bytes, and isDownloaded tracks
    /// the >10 MB threshold exactly.
    @Test func embedderPresenceIsConsistent() {
        let bytes = MLXTextEmbedder.shared.onDiskBytes()
        #expect(bytes >= 0)
        #expect(MLXTextEmbedder.shared.isDownloaded() == (bytes > 10_000_000))
    }

    /// Constants the wizard + Settings copy read.
    @Test func embedderConstantsStable() {
        #expect(MLXTextEmbedder.modelID == "sentence-transformers/all-MiniLM-L6-v2")
        #expect(MLXTextEmbedder.estimatedSizeMB == 90)
    }

    #endif
}
