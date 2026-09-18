import Testing
import Foundation
@testable import Ancestor_Research

/// Project onboarding Part A Step 2 (enable local AI). Step 2 is mostly a
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


}
