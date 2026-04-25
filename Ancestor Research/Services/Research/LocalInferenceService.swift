import Foundation
import os
import MLXLLM
import MLXLMCommon

/// Local reasoning model service using MLX on Apple Silicon.
///
/// This runs DeepSeek-R1 (a reasoning model, not a generic LLM).
/// It uses chain-of-thought with <think> tags to work through
/// genealogical problems: cluster evaluation, disambiguation,
/// strategy selection, and evidence summaries.
///
/// Architecture: deterministic-probabilistic-deterministic sandwich.
/// The reasoning model never decides facts — only reasons about
/// search directions, interprets relationships, and drafts conclusions.
/// When the model and deterministic engine disagree, deterministic wins.
actor LocalInferenceService {
    static let shared = LocalInferenceService()

    /// The default reasoning model — DeepSeek-R1 7B 4-bit.
    /// Pre-registered in LLMRegistry, no custom downloader needed.
    static let defaultConfiguration = LLMRegistry.deepSeekR1_7B_4bit

    private var modelContainer: ModelContainer?
    private var session: ChatSession?
    private var loadingTask: Task<ModelContainer, Error>?
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "Reasoning")

    /// Current model configuration.
    private(set) var currentModelID: String?

    /// Whether a model is loaded and ready.
    var isAvailable: Bool {
        modelContainer != nil
    }

    /// Whether a model is currently being loaded.
    var isLoading: Bool {
        loadingTask != nil
    }

    // MARK: - Model Lifecycle

    /// Load the reasoning model using a pre-registered LLMRegistry configuration.
    /// The 7B model is registered by default; for the 14B model, pass a custom
    /// ModelConfiguration with the desired HuggingFace ID.
    @discardableResult
    func loadModel(
        configuration: ModelConfiguration = defaultConfiguration
    ) async throws -> ModelContainer {
        // Already loaded
        if let existing = modelContainer, currentModelID == configuration.name {
            return existing
        }

        // Already loading
        if let task = loadingTask {
            return try await task.value
        }

        let config = configuration
        let task = Task<ModelContainer, Error> {
            logger.info("Loading reasoning model: \(config.name)")

            let container = try await LLMModelFactory.shared.loadContainer(
                from: HuggingFaceDownloader(),
                using: TransformersTokenizerLoader(),
                configuration: config
            ) { progress in
                // Progress updates handled by the framework
            }

            logger.info("Reasoning model loaded: \(config.name)")
            return container
        }

        loadingTask = task
        do {
            let container = try await task.value
            modelContainer = container
            currentModelID = configuration.name
            session = ChatSession(container)
            loadingTask = nil
            return container
        } catch {
            loadingTask = nil
            logger.error("Failed to load model: \(error.localizedDescription)")
            throw error
        }
    }

    /// Unload the model to free memory.
    func unload() {
        modelContainer = nil
        session = nil
        currentModelID = nil
        loadingTask = nil
        logger.info("Reasoning model unloaded")
    }

    // MARK: - Reasoning

    /// Send a prompt to the reasoning model and get the response.
    /// Returns nil if no model is loaded.
    ///
    /// The model uses chain-of-thought reasoning internally (<think> tags).
    /// We return the final answer after the reasoning phase.
    func reason(
        prompt: String,
        systemPrompt: String = "",
        maxTokens: Int = 2048
    ) async -> String? {
        guard let container = modelContainer else { return nil }

        do {
            // Build messages
            var messages: [[String: any Sendable]] = []
            if !systemPrompt.isEmpty {
                messages.append(["role": "system", "content": systemPrompt])
            }
            messages.append(["role": "user", "content": prompt])

            let userInput = UserInput(messages: messages)
            let lmInput = try await container.prepare(input: userInput)

            // Collect all generated text
            var fullText = ""
            let stream = try await container.generate(
                input: lmInput,
                parameters: GenerateParameters(temperature: 0.3)
            )
            for try await generation in stream {
                switch generation {
                case .chunk(let text):
                    fullText += text
                    if fullText.count > maxTokens * 4 { break } // rough token-to-char limit
                case .info:
                    break
                default:
                    break
                }
            }

            let response = fullText

            // Strip <think>...</think> tags — return only the final answer
            return stripThinkTags(from: response)
        } catch {
            logger.error("Reasoning failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Send a prompt and parse the response as JSON.
    /// Retries up to maxRetries times if JSON parsing fails.
    func reasonJSON(
        prompt: String,
        systemPrompt: String = "",
        maxTokens: Int = 2048,
        maxRetries: Int = 2
    ) async -> Any? {
        for attempt in 0...maxRetries {
            let effectivePrompt = attempt > 0
                ? prompt + "\n\nIMPORTANT: Respond with valid JSON only. No markdown, no explanation, just the JSON object."
                : prompt

            guard let raw = await reason(
                prompt: effectivePrompt, systemPrompt: systemPrompt, maxTokens: maxTokens
            ) else {
                return nil
            }

            if let parsed = extractJSON(from: raw) {
                return parsed
            }

            logger.warning("JSON parse failed (attempt \(attempt + 1)/\(maxRetries + 1))")
        }

        return nil
    }

    // MARK: - Response Processing

    /// Strip <think>...</think> reasoning blocks from the response.
    /// DeepSeek-R1 outputs its chain-of-thought in these tags.
    /// We preserve the final answer after the thinking phase.
    nonisolated private func stripThinkTags(from text: String) -> String {
        var result = text

        // Remove all <think>...</think> blocks
        while let thinkStart = result.range(of: "<think>"),
              let thinkEnd = result.range(of: "</think>", range: thinkStart.upperBound..<result.endIndex) {
            result.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
        }

        // Also handle unclosed <think> at end (model hit token limit mid-thought)
        if let thinkStart = result.range(of: "<think>") {
            result = String(result[..<thinkStart.lowerBound])
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JSON Extraction

    /// Try to extract JSON from text that might contain markdown or extra text.
    /// Faithfully ported from Python's _extract_json().
    nonisolated private func extractJSON(from text: String) -> Any? {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            return obj
        }

        if let jsonStart = text.range(of: "```json"),
           let blockEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) {
            let jsonText = String(text[jsonStart.upperBound..<blockEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = jsonText.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                return obj
            }
        }

        if let start = text.range(of: "```") {
            let afterStart = text[start.upperBound...]
            if let end = afterStart.range(of: "```") {
                let jsonText = String(afterStart[..<end.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let data = jsonText.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) {
                    return obj
                }
            }
        }

        for (open, close) in [("{", "}"), ("[", "]")] {
            if let startIdx = text.firstIndex(of: Character(open)),
               let endIdx = text.lastIndex(of: Character(close)),
               startIdx < endIdx {
                let jsonText = String(text[startIdx...endIdx])
                if let data = jsonText.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) {
                    return obj
                }
            }
        }

        return nil
    }
}
