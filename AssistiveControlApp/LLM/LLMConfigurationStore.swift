// LLMConfigurationStore.swift
// Observable store for LLM provider configuration.
// Non-sensitive config goes to UserDefaults; API keys go to Keychain.

import Foundation
import Security

private let kConfigKey      = "LLMConfiguration"
private let kOnboardingKey  = "hasCompletedOnboarding"
private let kKeychainService = "com.assistivecontrol.app"

@MainActor
final class LLMConfigurationStore: ObservableObject {

    @Published var configuration: LLMConfiguration
    @Published var hasCompletedOnboarding: Bool

    init() {
        // Load persisted configuration or fall back to defaults.
        if let data = UserDefaults.standard.data(forKey: kConfigKey),
           let decoded = try? JSONDecoder().decode(LLMConfiguration.self, from: data) {
            self.configuration = decoded
        } else {
            self.configuration = .default
        }
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: kOnboardingKey)
    }

    // MARK: - Persistence

    func save() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: kConfigKey)
        }
        UserDefaults.standard.set(hasCompletedOnboarding, forKey: kOnboardingKey)
    }

    // MARK: - Provider Factory

    /// Creates the correct LLMProvider from the current configuration.
    /// Called at send-time so config changes are always picked up.
    func makeProvider() -> any LLMProvider {
        switch configuration.providerType {
        case .anthropic:
            let key = apiKey(for: .anthropic) ?? ""
            return AnthropicLLMProvider(
                apiKey: key,
                model: configuration.anthropicModel
            )
        case .openai:
            let key = apiKey(for: .openai) ?? ""
            return OpenAILLMProvider(
                apiKey: key,
                model: configuration.openAIModel
            )
        case .localOllama:
            let url = URL(string: configuration.ollamaBaseURL)
                ?? URL(string: "http://localhost:11434")!
            return LocalLLMProvider(
                baseURL: url,
                model: configuration.ollamaModel
            )
        }
    }

    // MARK: - Keychain

    func saveAPIKey(_ key: String, for type: LLMProviderType) {
        let account = "apiKey.\(type.rawValue)"
        guard let data = key.data(using: .utf8) else { return }

        // Delete any existing item first.
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: kKeychainService as CFString,
            kSecAttrAccount: account as CFString
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add the new item.
        let addQuery: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     kKeychainService as CFString,
            kSecAttrAccount:     account as CFString,
            kSecValueData:       data,
            kSecAttrAccessible:  kSecAttrAccessibleWhenUnlocked
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    func apiKey(for type: LLMProviderType) -> String? {
        let account = "apiKey.\(type.rawValue)"
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      kKeychainService as CFString,
            kSecAttrAccount:      account as CFString,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }
}
