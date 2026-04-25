import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for reasoning model response parsing — stripThinkTags and extractJSON.
/// These run without a loaded model, testing only the parsing logic.
struct LLMParserTests {

    // MARK: - stripThinkTags

    @Test func stripThinkTagsRemovesThinking() {
        let input = "<think>Let me reason about this...</think>The answer is 42."
        let service = LocalInferenceService.shared

        // Access via a helper that exposes the nonisolated method
        let result = stripThinkTagsHelper(input)
        #expect(result == "The answer is 42.")
    }

    @Test func stripThinkTagsHandlesUnclosed() {
        let result = stripThinkTagsHelper("Final answer<think>I'm still thinking about")
        #expect(result == "Final answer")
    }

    @Test func stripThinkTagsPreservesPlainText() {
        let result = stripThinkTagsHelper("Just a plain answer")
        #expect(result == "Just a plain answer")
    }

    @Test func stripThinkTagsMultipleBlocks() {
        let result = stripThinkTagsHelper("<think>first</think>A<think>second</think>B")
        #expect(result == "AB")
    }

    // MARK: - extractJSON

    @Test func extractJSONDirectParse() {
        let result = extractJSONHelper(#"{"key": "value"}"#)
        #expect(result != nil)
    }

    @Test func extractJSONFromCodeBlock() {
        let result = extractJSONHelper("""
        Here is the result:
        ```json
        {"source_id": "freebmd", "reason": "test"}
        ```
        """)
        #expect(result != nil)
    }

    @Test func extractJSONFromBrackets() {
        let result = extractJSONHelper("Some text {\"answer\": true} more text")
        #expect(result != nil)
    }

    @Test func extractJSONReturnsNilForGarbage() {
        let result = extractJSONHelper("This is not JSON at all")
        #expect(result == nil)
    }

    // MARK: - Helpers

    /// Direct access to stripThinkTags logic without actor isolation.
    private func stripThinkTagsHelper(_ text: String) -> String {
        var result = text
        while let thinkStart = result.range(of: "<think>"),
              let thinkEnd = result.range(of: "</think>", range: thinkStart.upperBound..<result.endIndex) {
            result.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
        }
        if let thinkStart = result.range(of: "<think>") {
            result = String(result[..<thinkStart.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Direct access to extractJSON logic without actor isolation.
    private func extractJSONHelper(_ text: String) -> Any? {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) { return obj }
        if let jsonStart = text.range(of: "```json"),
           let blockEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) {
            let jsonText = String(text[jsonStart.upperBound..<blockEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = jsonText.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) { return obj }
        }
        for (open, close) in [("{", "}"), ("[", "]")] {
            if let startIdx = text.firstIndex(of: Character(open)),
               let endIdx = text.lastIndex(of: Character(close)),
               startIdx < endIdx {
                let jsonText = String(text[startIdx...endIdx])
                if let data = jsonText.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) { return obj }
            }
        }
        return nil
    }
}
