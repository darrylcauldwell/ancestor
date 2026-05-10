import Foundation
import os

#if !FIELD_RESEARCHER_DISABLED

/// Claude Messages API client for the Field Researcher.
/// Handles multi-turn conversations with tool use and cost tracking.
actor ClaudeAPIClient {
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "ClaudeAPI")

    private var apiKey: String
    private var model: String
    private(set) var sessionTokensInput: Int = 0
    private(set) var sessionTokensOutput: Int = 0

    private static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    init(apiKey: String, model: String = "claude-sonnet-4-20250514") {
        self.apiKey = apiKey
        self.model = model
    }

    func updateCredentials(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    func resetSessionCost() {
        sessionTokensInput = 0
        sessionTokensOutput = 0
    }

    /// Estimated cost in USD based on current token counts.
    var estimatedCost: Double {
        // Pricing as of 2025 — Sonnet: $3/M input, $15/M output
        // Opus: $15/M input, $75/M output
        let inputRate: Double
        let outputRate: Double
        if model.contains("opus") {
            inputRate = 15.0 / 1_000_000
            outputRate = 75.0 / 1_000_000
        } else {
            inputRate = 3.0 / 1_000_000
            outputRate = 15.0 / 1_000_000
        }
        return Double(sessionTokensInput) * inputRate + Double(sessionTokensOutput) * outputRate
    }

    // MARK: - Messages API

    /// Send a message and get a response. Supports tool use.
    func send(
        system: String,
        messages: [ConversationMessage],
        tools: [ClaudeTool]? = nil,
        maxTokens: Int = 4096
    ) async throws -> ClaudeResponse {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages.map { msg in msg.toDict() },
        ]

        if !system.isEmpty {
            body["system"] = system
        }

        if let tools, !tools.isEmpty {
            body["tools"] = tools.map { $0.toDict() }
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.networkError("not HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            if httpResponse.statusCode == 429 {
                throw ClaudeAPIError.rateLimited
            }
            if httpResponse.statusCode == 401 {
                throw ClaudeAPIError.invalidAPIKey
            }
            throw ClaudeAPIError.httpError(httpResponse.statusCode, errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeAPIError.parseError("invalid JSON response")
        }

        // Track token usage
        if let usage = json["usage"] as? [String: Any] {
            sessionTokensInput += usage["input_tokens"] as? Int ?? 0
            sessionTokensOutput += usage["output_tokens"] as? Int ?? 0
        }

        return parseResponse(json)
    }

    // MARK: - Response Parsing

    private func parseResponse(_ json: [String: Any]) -> ClaudeResponse {
        let stopReason = json["stop_reason"] as? String ?? ""
        let content = json["content"] as? [[String: Any]] ?? []

        var textParts: [String] = []
        var toolCalls: [ClaudeToolCall] = []

        for block in content {
            let type = block["type"] as? String ?? ""
            if type == "text" {
                textParts.append(block["text"] as? String ?? "")
            } else if type == "tool_use" {
                let call = ClaudeToolCall(
                    id: block["id"] as? String ?? "",
                    name: block["name"] as? String ?? "",
                    input: block["input"] as? [String: Any] ?? [:]
                )
                toolCalls.append(call)
            }
        }

        return ClaudeResponse(
            text: textParts.joined(),
            toolCalls: toolCalls,
            stopReason: stopReason,
            inputTokens: sessionTokensInput,
            outputTokens: sessionTokensOutput
        )
    }
}

// MARK: - Types

struct ConversationMessage: @unchecked Sendable {
    let role: String  // "user" or "assistant"
    let content: MessageContent

    enum MessageContent: Sendable {
        case text(String)
        case toolResult(toolUseID: String, content: String)
        case mixed([ContentBlock])
    }

    enum ContentBlock: @unchecked Sendable {
        case text(String)
        case toolUse(id: String, name: String, input: [String: Any])
        case toolResult(toolUseID: String, content: String)
    }

    nonisolated func toDict() -> [String: Any] {
        switch content {
        case .text(let text):
            return ["role": role, "content": text]
        case .toolResult(let id, let result):
            return ["role": role, "content": [
                ["type": "tool_result", "tool_use_id": id, "content": result]
            ]]
        case .mixed(let blocks):
            return ["role": role, "content": blocks.map { block -> [String: Any] in
                switch block {
                case .text(let text):
                    return ["type": "text", "text": text]
                case .toolUse(let id, let name, let input):
                    return ["type": "tool_use", "id": id, "name": name, "input": input]
                case .toolResult(let id, let content):
                    return ["type": "tool_result", "tool_use_id": id, "content": content]
                }
            }]
        }
    }
}

nonisolated struct ClaudeTool: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    nonisolated func toDict() -> [String: Any] {
        ["name": name, "description": description, "input_schema": inputSchema]
    }
}

nonisolated struct ClaudeToolCall: @unchecked Sendable {
    let id: String
    let name: String
    let input: [String: Any]
}

nonisolated struct ClaudeResponse: Sendable {
    let text: String
    let toolCalls: [ClaudeToolCall]
    let stopReason: String
    let inputTokens: Int
    let outputTokens: Int

    var hasToolCalls: Bool { !toolCalls.isEmpty }
    var isEndTurn: Bool { stopReason == "end_turn" }
}

nonisolated enum ClaudeAPIError: LocalizedError {
    case invalidAPIKey
    case rateLimited
    case httpError(Int, String)
    case networkError(String)
    case parseError(String)
    case budgetExceeded

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: "Invalid API key — check Settings"
        case .rateLimited: "Rate limited — try again shortly"
        case .httpError(let code, let body): "HTTP \(code): \(body.prefix(200))"
        case .networkError(let msg): "Network error: \(msg)"
        case .parseError(let msg): "Parse error: \(msg)"
        case .budgetExceeded: "Session budget exceeded"
        }
    }
}

#endif
