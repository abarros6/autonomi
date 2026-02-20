// LLMConfiguration.swift
// Defines the provider type enum and the non-sensitive configuration struct.
// API keys are never stored here — they live in Keychain via LLMConfigurationStore.

import Foundation

/// The set of LLM backends the app supports.
enum LLMProviderType: String, Codable, CaseIterable {
    case anthropic   = "anthropic"
    case openai      = "openai"
    case localOllama = "localOllama"

    var displayName: String {
        switch self {
        case .anthropic:   return "Claude (Anthropic)"
        case .openai:      return "GPT (OpenAI)"
        case .localOllama: return "Local Ollama"
        }
    }
}

/// Non-sensitive configuration for the active LLM provider.
/// Persisted to UserDefaults. API keys are stored separately in Keychain.
struct LLMConfiguration: Codable {
    var providerType: LLMProviderType
    var anthropicModel: String
    var openAIModel: String
    var ollamaBaseURL: String
    var ollamaModel: String

    static let `default` = LLMConfiguration(
        providerType: .localOllama,
        anthropicModel: "claude-sonnet-4-6",
        openAIModel: "gpt-4o",
        ollamaBaseURL: "http://localhost:11434",
        ollamaModel: "llama3.2"
    )
}
