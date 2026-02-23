// OpenAILLMProvider.swift
// Sends conversation history to the OpenAI Chat Completions API and decodes the
// response into a structured Intent.
//
// Security invariants:
//   - No shell execution, no Process(), no filesystem writes.
//   - Only contacts api.openai.com — no other external network calls.
//   - All model output is treated as untrusted; decodeIntent is the isolation boundary.
//   - On any parse failure, a structured error is surfaced — no silent fallbacks.

import Foundation

/// Calls POST https://api.openai.com/v1/chat/completions and decodes the response into an Intent.
final class OpenAILLMProvider: LLMProvider {

    // MARK: - Configuration

    private let apiKey: String
    private let model: String
    private let session: URLSession

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// - Parameters:
    ///   - apiKey: OpenAI API key (loaded from Keychain at call time).
    ///   - model:  OpenAI model ID, e.g. `gpt-4o`.
    ///   - session: URLSession for dependency injection in tests (defaults to shared).
    init(
        apiKey: String,
        model: String = "gpt-4o",
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

        // OpenAI uses the standard messages array format with a system role prepended.
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for message in conversation {
            guard message.role != .system else { continue }
            messages.append([
                "role": message.role.rawValue,
                "content": message.content
            ])
        }

        let requestBody: [String: Any] = [
            "model": model,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json",       forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)",        forHTTPHeaderField: "Authorization")
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

    /// Extracts the raw content string from the OpenAI chat completions response.
    /// Expected shape: { "choices": [ { "message": { "content": "..." } } ] }
    private func extractContent(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMProviderError.malformedResponse("Response body is not a JSON object.")
        }

        guard
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw LLMProviderError.malformedResponse("Response missing 'choices[0].message.content' field.")
        }

        return content
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
