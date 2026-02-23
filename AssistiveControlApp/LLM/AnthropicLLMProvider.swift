// AnthropicLLMProvider.swift
// Sends conversation history to the Anthropic Messages API and decodes the response
// into a structured Intent.
//
// Security invariants:
//   - No shell execution, no Process(), no filesystem writes.
//   - Only contacts api.anthropic.com — no other external network calls.
//   - All model output is treated as untrusted; decodeIntent is the isolation boundary.
//   - On any parse failure, a structured error is surfaced — no silent fallbacks.

import Foundation

/// Calls POST https://api.anthropic.com/v1/messages and decodes the response into an Intent.
final class AnthropicLLMProvider: LLMProvider {

    // MARK: - Configuration

    private let apiKey: String
    private let model: String
    private let session: URLSession

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// - Parameters:
    ///   - apiKey: Anthropic API key (loaded from Keychain at call time).
    ///   - model:  Claude model ID, e.g. `claude-sonnet-4-6`.
    ///   - session: URLSession for dependency injection in tests (defaults to shared).
    init(
        apiKey: String,
        model: String = "claude-sonnet-4-6",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    // MARK: - LLMProvider

    func generateIntent(
        conversation: [LLMMessage],
        availableActions: [ActionDescriptor]
    ) async throws -> Intent {
        let systemPrompt = assembleSystemPrompt(availableActions: availableActions)

        // Anthropic requires system prompt as a top-level field, not in the messages array.
        // Messages array must only contain user/assistant turns.
        var messages: [[String: String]] = []
        for message in conversation {
            guard message.role != .system else { continue }
            messages.append([
                "role": message.role.rawValue,
                "content": message.content
            ])
        }

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json",      forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey,                  forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",            forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.malformedResponse("Response is not an HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw LLMProviderError.httpError(statusCode: httpResponse.statusCode)
        }

        let rawContent = try extractContent(from: data)
        return try decodeIntent(rawContent)
    }

    // MARK: - Internal: System Prompt Assembly

    /// Delegates to the shared buildSystemPrompt function defined in SystemPrompt.swift.
    private func assembleSystemPrompt(availableActions: [ActionDescriptor]) -> String {
        buildSystemPrompt(availableActions: availableActions)
    }

    // MARK: - Internal: Response Envelope Parsing

    /// Extracts the raw content string from the Anthropic Messages API response.
    /// Expected shape: { "content": [ { "type": "text", "text": "..." } ], ... }
    private func extractContent(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMProviderError.malformedResponse("Response body is not a JSON object.")
        }

        guard
            let content = json["content"] as? [[String: Any]],
            let first = content.first,
            let text = first["text"] as? String
        else {
            throw LLMProviderError.malformedResponse("Response missing 'content[0].text' field.")
        }

        return text
    }

    // MARK: - Internal: Intent Decoding (independently testable)

    func decodeIntent(_ raw: String) throws -> Intent {
        let cleaned = stripMarkdownFences(from: raw)

        guard let data = cleaned.data(using: .utf8) else {
            throw LLMProviderError.parseError("Could not encode response string as UTF-8.")
        }

        do {
            return try JSONDecoder().decode(Intent.self, from: data)
        } catch {
            throw LLMProviderError.parseError("JSON decoding failed: \(error.localizedDescription). Raw: \(raw)")
        }
    }

    // MARK: - Private Helpers

    private func stripMarkdownFences(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            if let newlineIndex = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newlineIndex)...])
            }
            if result.hasSuffix("```") {
                result = String(result.dropLast(3))
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
