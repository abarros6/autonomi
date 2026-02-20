// LLMProvider.swift
// Protocol defining the LLM abstraction boundary.
// The LLM is a planner only — it never executes actions directly.
// All implementations must treat their output as untrusted input.

import Foundation

/// Abstraction over any LLM backend (local Ollama, future cloud provider, test mock).
/// Conforming types accept a conversation and the current action schema, and return
/// a structured Intent. The returned Intent is always untrusted and must be validated
/// by IntentValidator before any execution occurs.
protocol LLMProvider {
    /// Parse the user's conversation into a structured Intent.
    /// - Parameters:
    ///   - conversation: Full message history for the current session.
    ///   - availableActions: The current registry of supported actions, serialized
    ///                       into the system prompt so the model knows the schema.
    /// - Returns: A raw, unvalidated Intent decoded from model output.
    /// - Throws: LLMProviderError on network failure, non-2xx status, or JSON parse failure.
    func generateIntent(
        conversation: [LLMMessage],
        availableActions: [ActionDescriptor]
    ) async throws -> Intent
}

/// Typed errors from the LLM provider layer.
enum LLMProviderError: Error, LocalizedError {
    /// The HTTP response carried a non-2xx status code.
    case httpError(statusCode: Int)

    /// The response body could not be decoded as a valid Intent.
    case parseError(String)

    /// The response was structurally valid JSON but semantically malformed
    /// (e.g. missing required top-level fields, done: false).
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "LLM request failed with HTTP \(code)."
        case .parseError(let detail):
            return "Failed to parse LLM response: \(detail)"
        case .malformedResponse(let detail):
            return "Malformed LLM response: \(detail)"
        }
    }
}
