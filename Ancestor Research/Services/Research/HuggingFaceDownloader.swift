import Foundation
import MLXLMCommon
import Tokenizers

/// Minimal Hugging Face Hub downloader — downloads model snapshots to local cache.
/// Implements the MLXLMCommon.Downloader protocol.
struct HuggingFaceDownloader: Downloader {
    private let cacheDir: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir = appSupport.appendingPathComponent("dev.dreamfold.Ancestor-Research/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let safeName = id.replacingOccurrences(of: "/", with: "--")
        let modelDir = cacheDir.appendingPathComponent(safeName, isDirectory: true)

        // Check if already cached
        let configPath = modelDir.appendingPathComponent("config.json")
        if !useLatest && FileManager.default.fileExists(atPath: configPath.path) {
            return modelDir
        }

        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        // Fetch file listing from HF Hub API
        let rev = revision ?? "main"
        let apiURL = URL(string: "https://huggingface.co/api/models/\(id)/tree/\(rev)")!
        let (listData, _) = try await URLSession.shared.data(from: apiURL)

        guard let files = try JSONSerialization.jsonObject(with: listData) as? [[String: Any]] else {
            throw HFDownloadError.invalidResponse
        }

        let filenames = files.compactMap { $0["path"] as? String }
        let matched = filenames.filter { name in
            patterns.isEmpty || patterns.contains { pattern in
                matchGlob(pattern: pattern, string: name)
            }
        }

        let progress = Progress(totalUnitCount: Int64(matched.count))
        progressHandler(progress)

        for filename in matched {
            let fileURL = URL(string: "https://huggingface.co/\(id)/resolve/\(rev)/\(filename)")!
            let destPath = modelDir.appendingPathComponent(filename)

            if FileManager.default.fileExists(atPath: destPath.path) {
                progress.completedUnitCount += 1
                progressHandler(progress)
                continue
            }

            let parent = destPath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

            let (data, response) = try await URLSession.shared.data(from: fileURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw HFDownloadError.downloadFailed(filename)
            }

            try data.write(to: destPath)
            progress.completedUnitCount += 1
            progressHandler(progress)
        }

        return modelDir
    }

    private func matchGlob(pattern: String, string: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasPrefix("*.") {
            let ext = String(pattern.dropFirst(2))
            return string.hasSuffix(".\(ext)")
        }
        return string == pattern
    }
}

/// Loads tokenizer from a local directory using swift-transformers.
/// Bridges Tokenizers.Tokenizer to MLXLMCommon.Tokenizer.
struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

/// Bridges swift-transformers Tokenizer to MLXLMCommon.Tokenizer.
private struct TokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let upstream: Tokenizers.Tokenizer

    init(_ upstream: Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { nil }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        // Convert to the format swift-transformers expects
        let chatMessages = messages.map { msg -> [String: String] in
            var result: [String: String] = [:]
            if let role = msg["role"] as? String { result["role"] = role }
            if let content = msg["content"] as? String { result["content"] = content }
            return result
        }
        return try upstream.applyChatTemplate(messages: chatMessages)
    }
}

nonisolated enum HFDownloadError: LocalizedError {
    case invalidResponse
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from Hugging Face API"
        case .downloadFailed(let file): "Failed to download \(file)"
        }
    }
}
