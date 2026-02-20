// LocalLLMProvider.swift
// Connects to a locally running Ollama instance via POST /api/chat.
//
// Security invariants:
//   - No shell execution, no Process(), no filesystem writes.
//   - Only contacts the injected baseURL — no other external network calls.
//   - All model output is treated as untrusted; decodeIntent is the isolation boundary.
//   - On any parse failure, a structured error is surfaced — no silent fallbacks, no retries.

import Foundation

/// Sends conversation history to a local Ollama instance and decodes the response into an Intent.
/// Both `baseURL` and `model` are injected — never hardcoded.
final class LocalLLMProvider: LLMProvider {

    // MARK: - Configuration

    private let baseURL: URL
    private let model: String
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: Ollama server root, e.g. `http://localhost:11434`
    ///   - model:   Ollama model tag, e.g. `llama3.2`
    ///   - session: URLSession for dependency injection in tests (defaults to shared)
    init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        model: String = "llama3.2",
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    // MARK: - LLMProvider

    func generateIntent(
        conversation: [LLMMessage],
        availableActions: [ActionDescriptor]
    ) async throws -> Intent {
        let endpoint = baseURL.appendingPathComponent("/api/chat")

        // Assemble the system prompt dynamically at call time from live registry state.
        let systemPrompt = assembleSystemPrompt(availableActions: availableActions)

        // Build message array: system message first, then conversation history.
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for message in conversation {
            messages.append(["role": message.role.rawValue, "content": message.content])
        }

        let requestBody: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.malformedResponse("Response is not an HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw LLMProviderError.httpError(statusCode: httpResponse.statusCode)
        }

        // Parse the Ollama response envelope and extract the content string.
        let rawContent = try extractContent(from: data)

        // Isolate intent decoding so it is independently testable.
        return try decodeIntent(rawContent)
    }

    // MARK: - Internal: System Prompt Assembly

    /// Assembles the LLM system prompt by appending the serialized action schema
    /// to the base instruction. Called at request time so the schema is always current.
    private func assembleSystemPrompt(availableActions: [ActionDescriptor]) -> String {
        let base = """
        You are an intent parser for a macOS assistive control system. \
        You must output ONLY valid JSON matching the provided schema. \
        Do not include prose. Do not include explanations. Only return JSON. \
        If the request cannot be mapped to a supported intent, return: \
        {"intent": "unsupported", "parameters": {}}.
        """

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        let schemaJSON: String
        if let data = try? encoder.encode(availableActions),
           let json = String(data: data, encoding: .utf8) {
            schemaJSON = json
        } else {
            schemaJSON = "[]"
        }

        return """
        \(base)

        Available actions:
        \(schemaJSON)

        Output must conform to: {"intent": "<name>", "parameters": {"<key>": "<value>"}, "confidence": <0.0-1.0>}
        """
    }

    // MARK: - Internal: Response Envelope Parsing

    /// Extracts the raw content string from the Ollama /api/chat response envelope.
    /// Throws LLMProviderError.malformedResponse if the envelope structure is invalid.
    private func extractContent(from data: Data) throws -> String {
        // Expected shape: { "model": "...", "message": { "role": "assistant", "content": "..." }, "done": true }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMProviderError.malformedResponse("Response body is not a JSON object.")
        }

        guard let done = json["done"] as? Bool, done else {
            throw LLMProviderError.malformedResponse("Response 'done' field is false or missing — stream not complete.")
        }

        guard
            let message = json["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw LLMProviderError.malformedResponse("Response missing 'message.content' field.")
        }

        return content
    }

    // MARK: - Internal: Intent Decoding (independently testable)

    /// Decodes a raw string (the model's output) into a validated Intent value.
    /// This function is `internal` (not `private`) so it can be tested directly.
    ///
    /// - Parameter raw: The raw string content from the LLM response.
    /// - Returns: A decoded Intent. The caller must still run IntentValidator.
    /// - Throws: LLMProviderError.parseError if the string is not valid Intent JSON.
    func decodeIntent(_ raw: String) throws -> Intent {
        // Strip any markdown code fences the model may have wrapped around the JSON.
        let cleaned = stripMarkdownFences(from: raw)

        guard let data = cleaned.data(using: .utf8) else {
            throw LLMProviderError.parseError("Could not encode response string as UTF-8.")
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(Intent.self, from: data)
        } catch {
            throw LLMProviderError.parseError("JSON decoding failed: \(error.localizedDescription). Raw: \(raw)")
        }
    }

    // MARK: - Private Helpers

    /// Strips optional markdown code fences (```json ... ``` or ``` ... ```) from model output.
    private func stripMarkdownFences(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            // Remove opening fence and optional language tag (e.g. ```json)
            if let newlineIndex = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newlineIndex)...])
            }
            // Remove closing fence
            if result.hasSuffix("```") {
                result = String(result.dropLast(3))
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
