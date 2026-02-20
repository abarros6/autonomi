// CloudLLMProvider.swift
// Stub implementation — cloud LLM calls are a v2 feature.
// Do not implement actual network calls here until v2.

import Foundation

/// Stub conformance to LLMProvider for a future cloud-backed LLM.
/// Always throws to make accidental use in v1 immediately visible.
final class CloudLLMProvider: LLMProvider {
    func generateIntent(
        conversation: [LLMMessage],
        availableActions: [ActionDescriptor]
    ) async throws -> Intent {
        // STUB — not implemented in v1.
        // Cloud LLM integration is deferred to v2.
        throw LLMProviderError.malformedResponse("CloudLLMProvider is not implemented in v1.")
    }
}
