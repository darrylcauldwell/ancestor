import Foundation
import os
import MLXLLM
import MLXLMCommon

/// User-selectable reasoning model. The Settings picker persists the
/// raw value via `@AppStorage("reasoningModelChoice")` and passes the
/// matching `configuration` to `LocalInferenceService.loadModel(...)`.
///
/// Some options are pre-registered in `LLMRegistry`; the rest are
/// constructed inline by HuggingFace repo ID. Gemma 4 E4B deliberately
/// uses the QAT repo, NOT the registry's `gemma4_e4b_it_4bit`: the
/// plain 4-bit quant (Apr 2026) has broken PLE layers that produce
/// garbage output and was never requantized.
public nonisolated enum ReasoningModel: String, CaseIterable, Sendable, Identifiable {
    case qwen35_4B = "qwen-3.5-4b"
    case gemma4_E4B = "gemma-4-e4b"
    case deepSeekR1_7B = "deepseek-r1-7b"
    case qwen25_7B = "qwen-2.5-7b"
    case qwen25_14B = "qwen-2.5-14b"
    case deepSeekR1_14B = "deepseek-r1-14b"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen35_4B: "Qwen3.5 4B (4-bit)"
        case .gemma4_E4B: "Gemma 4 E4B QAT (4-bit)"
        case .deepSeekR1_7B: "DeepSeek-R1 Distill Qwen 7B (4-bit)"
        case .qwen25_7B: "Qwen 2.5 7B Instruct (4-bit)"
        case .qwen25_14B: "Qwen 2.5 14B Instruct (4-bit)"
        case .deepSeekR1_14B: "DeepSeek-R1 Distill Qwen 14B (4-bit)"
        }
    }

    public var subtitle: String {
        switch self {
        case .qwen35_4B: "Recommended — strongest instruction-following per GB; thinking disabled for deterministic latency"
        case .gemma4_E4B: "Alternative with native function-call tokens; higher RAM"
        case .deepSeekR1_7B: "Legacy chain-of-thought model; weak instruction following"
        case .qwen25_7B: "Previous-generation instruct model, no <think> tags"
        case .qwen25_14B: "Previous-generation 14B; superseded by Qwen3.5 4B"
        case .deepSeekR1_14B: "Legacy chain-of-thought; slower, highest RAM"
        }
    }

    public var memoryEstimateGB: Double {
        switch self {
        case .qwen35_4B: 4.0
        case .deepSeekR1_7B, .qwen25_7B: 4.5
        case .gemma4_E4B: 7.5
        case .qwen25_14B, .deepSeekR1_14B: 8.5
        }
    }

    public var configuration: ModelConfiguration {
        switch self {
        case .qwen35_4B: ModelConfiguration(id: "mlx-community/Qwen3.5-4B-MLX-4bit")
        case .gemma4_E4B: ModelConfiguration(id: "mlx-community/gemma-4-E4B-it-qat-4bit")
        case .deepSeekR1_7B: LLMRegistry.deepSeekR1_7B_4bit
        case .qwen25_7B: LLMRegistry.qwen2_5_7b
        case .qwen25_14B: ModelConfiguration(id: "mlx-community/Qwen2.5-14B-Instruct-4bit")
        case .deepSeekR1_14B: ModelConfiguration(id: "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit")
        }
    }

    /// HuggingFace repo ID — equivalent to `configuration.name` but
    /// reachable from callers that don't import `MLXLMCommon`.
    public var huggingFaceID: String {
        switch self {
        case .qwen35_4B: "mlx-community/Qwen3.5-4B-MLX-4bit"
        case .gemma4_E4B: "mlx-community/gemma-4-E4B-it-qat-4bit"
        case .deepSeekR1_7B: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit"
        case .qwen25_7B: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        case .qwen25_14B: "mlx-community/Qwen2.5-14B-Instruct-4bit"
        case .deepSeekR1_14B: "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit"
        }
    }

    public static let `default`: ReasoningModel = .qwen35_4B
}

/// Local reasoning model service using MLX on Apple Silicon.
///
/// Runs whichever open-weight model the user selects in Settings
/// (`ReasoningModel`) for the app's bounded advisory tasks: search
/// strategy suggestions, candidate comparison, and prose-fact
/// extraction. Thinking/chain-of-thought is disabled where the
/// model's chat template supports it — these tasks need schema-valid
/// output, not visible reasoning.
///
/// Architecture: deterministic-probabilistic-deterministic sandwich.
/// The reasoning model never decides facts — only reasons about
/// search directions, interprets relationships, and drafts conclusions.
/// When the model and deterministic engine disagree, deterministic wins.
actor LocalInferenceService {
    static let shared = LocalInferenceService()

    /// Single source of truth for the default: `ReasoningModel.default`.
    static let defaultConfiguration = ReasoningModel.default.configuration

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

    // MARK: - Sandbox model directory + seeding

    /// Errors raised by the seed-from-existing flow.
    public enum SeedError: LocalizedError {
        case noSandboxPath
        case sourceUnreadable(URL)
        case noModelFilesFound(URL)

        public var errorDescription: String? {
            switch self {
            case .noSandboxPath: "Could not resolve the app's model directory."
            case .sourceUnreadable(let url): "Cannot read \(url.path). Pick the folder again."
            case .noModelFilesFound(let url): "No .safetensors files in \(url.lastPathComponent). Pick the model's snapshot folder (or its parent that contains snapshots/ and blobs/)."
            }
        }
    }

    /// The on-disk path the MLX downloader writes a given configuration into.
    /// Mirrors HuggingFaceDownloader's convention: `Application Support/{bundle}/models/{org--repo}/`.
    nonisolated func sandboxModelDirectory(for model: ReasoningModel) -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.dreamfold.Ancestor-Research"
        let folderName = model.huggingFaceID.replacingOccurrences(of: "/", with: "--")
        return appSupport
            .appendingPathComponent(bundleID)
            .appendingPathComponent("models")
            .appendingPathComponent(folderName)
    }

    /// Total bytes already on disk for the given model. Used by Settings to
    /// show truthful download progress that doesn't depend on the framework's
    /// callback granularity.
    nonisolated func onDiskBytes(for model: ReasoningModel) -> Int64 {
        guard let dir = sandboxModelDirectory(for: model) else { return 0 }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Seed the sandbox model directory by copying files from a user-picked
    /// folder (typically a HuggingFace cache snapshot). Walks `source`
    /// recursively, dereferencing symlinks; copies anything matching a model
    /// or tokenizer file extension. Skips files already present at the
    /// destination with identical size.
    ///
    /// Returns the number of files copied.
    nonisolated func seedFromExternalDirectory(
        source: URL,
        for model: ReasoningModel
    ) throws -> Int {
        guard let dest = sandboxModelDirectory(for: model) else {
            throw SeedError.noSandboxPath
        }
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            throw SeedError.sourceUnreadable(source)
        }

        let acceptedExtensions: Set<String> = ["safetensors", "json", "txt"]
        var copied = 0
        var sawAnyModelFile = false

        for case let url as URL in enumerator {
            // Resolve symlinks (HF cache stores files as symlinks into blobs/).
            let resolved = url.resolvingSymlinksInPath()
            guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }

            let ext = url.pathExtension.lowercased()
            guard acceptedExtensions.contains(ext) else { continue }

            if ext == "safetensors" { sawAnyModelFile = true }

            let destURL = dest.appendingPathComponent(url.lastPathComponent)

            // Skip if a file of the same size already exists.
            if let existing = try? destURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               existing == size {
                continue
            }
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: resolved, to: destURL)
            copied += 1
        }

        if !sawAnyModelFile {
            throw SeedError.noModelFilesFound(source)
        }
        return copied
    }

    // MARK: - Model Lifecycle

    /// Load the reasoning model using a pre-registered LLMRegistry configuration.
    /// The 7B model is registered by default; for the 14B model, pass a custom
    /// ModelConfiguration with the desired HuggingFace ID.
    ///
    /// `onProgress` (if supplied) is invoked with a 0.0–1.0 fraction during
    /// download and weight resolution. The callback is `@Sendable` and may
    /// fire on any thread — UI consumers should hop to MainActor inside it.
    @discardableResult
    func loadModel(
        configuration: ModelConfiguration = defaultConfiguration,
        onProgress: (@Sendable (Double) -> Void)? = nil
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
                onProgress?(progress.fractionCompleted)
            }

            logger.info("Reasoning model loaded: \(config.name)")
            return container
        }

        loadingTask = task
        do {
            let container = try await task.value
            modelContainer = container
            currentModelID = configuration.name
            session = ChatSession(
                container,
                additionalContext: Self.templateContext(for: configuration.name)
            )
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

            let userInput = UserInput(
                messages: messages,
                additionalContext: Self.templateContext(for: currentModelID)
            )
            let lmInput = try await container.prepare(input: userInput)

            // Collect all generated text. maxTokens is enforced by the
            // generator itself — a char-count heuristic here used to cut
            // JSON mid-object, which strict parsers then rejected.
            var fullText = ""
            let stream = try await container.generate(
                input: lmInput,
                parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.3)
            )
            for try await generation in stream {
                switch generation {
                case .chunk(let text):
                    fullText += text
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

            if let parsed = Self.extractJSON(from: raw) {
                return parsed
            }

            logger.warning("JSON parse failed (attempt \(attempt + 1)/\(maxRetries + 1))")
        }

        return nil
    }

    // MARK: - Response Processing

    /// Chat-template kwargs merged into the Jinja render context by
    /// `applyChatTemplate(messages:tools:additionalContext:)`.
    /// Qwen3/Qwen3.5 hybrid-thinking templates read `enable_thinking`;
    /// think-tokens are pure latency here because a rules layer
    /// validates all output. Other models' templates ignore unknown
    /// kwargs, but return nil anyway so their input is byte-identical
    /// to before. `stripThinkTags` stays as the safety net — the flag
    /// is occasionally ignored, and DeepSeek-R1 has no such switch.
    nonisolated private static func templateContext(for modelID: String?) -> [String: any Sendable]? {
        guard let modelID, modelID.lowercased().contains("qwen3") else { return nil }
        return ["enable_thinking": false]
    }

    /// Strip <think>...</think> reasoning blocks from the response.
    /// Reasoning models (DeepSeek-R1; Qwen3.5 when the template flag
    /// is ignored) emit chain-of-thought in these tags.
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
    ///
    /// This is THE json-from-model-output parser: every call site that
    /// consumes `reason()` output must go through it (or the typed
    /// convenience below) rather than raw `JSONSerialization` — models
    /// routinely wrap JSON in code fences or preamble, and a strict
    /// parse silently discards otherwise-valid suggestions.
    nonisolated static func extractJSON(from text: String) -> Any? {
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

    /// Typed convenience over `extractJSON(from:)` for the common
    /// single-object case.
    nonisolated static func extractJSONDictionary(from text: String) -> [String: Any]? {
        extractJSON(from: text) as? [String: Any]
    }
}
