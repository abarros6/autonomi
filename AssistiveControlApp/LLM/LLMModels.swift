// LLMModels.swift
// Shared data transfer types used by the LLM abstraction layer.

import Foundation

/// A single message in an LLM conversation turn.
struct LLMMessage: Codable, Equatable {
    enum Role: String, Codable {
        case system
        case user
        case assistant
    }

    let role: Role
    let content: String
}

/// Declares a single action the system knows how to execute.
/// Used by ActionRegistry to register capabilities and by LocalLLMProvider
/// to assemble the dynamic system prompt so the LLM knows the exact schema.
struct ActionDescriptor: Codable {
    /// Matches the Intent.intent string — must be unique across all descriptors.
    let name: String

    /// Human-readable description included in the LLM system prompt.
    let description: String

    /// Parameter keys that must be present and non-empty for this action.
    let requiredParameters: [String]

    /// Parameter keys that may optionally be present.
    let optionalParameters: [String]
}
