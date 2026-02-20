// OnboardingView.swift
// Three-step flow for selecting and configuring an LLM provider.
// Also used as a settings sheet when the user taps the gear icon mid-session.

import SwiftUI

// MARK: - Step Enum

private enum OnboardingStep {
    case chooseProvider
    case configure
    case result(success: Bool, message: String)
}

// MARK: - OnboardingView

struct OnboardingView: View {

    @ObservedObject var configStore: LLMConfigurationStore

    /// When true, skip straight to the configure step (reconfiguration flow from gear icon).
    var isReconfiguring: Bool = false

    /// Called when the user taps Finish on the success result screen.
    var onFinish: () -> Void = {}

    @State private var step: OnboardingStep
    @State private var selectedProvider: LLMProviderType
    @State private var anthropicKey: String = ""
    @State private var openAIKey: String = ""
    @State private var ollamaURL: String = ""
    @State private var ollamaModel: String = ""
    @State private var selectedAnthropicModel: String = ""
    @State private var selectedOpenAIModel: String = ""
    @State private var isTesting = false

    init(configStore: LLMConfigurationStore, isReconfiguring: Bool = false, onFinish: @escaping () -> Void = {}) {
        self.configStore = configStore
        self.isReconfiguring = isReconfiguring
        self.onFinish = onFinish

        let config = configStore.configuration
        _selectedProvider = State(initialValue: config.providerType)
        _selectedAnthropicModel = State(initialValue: config.anthropicModel)
        _selectedOpenAIModel = State(initialValue: config.openAIModel)
        _ollamaURL = State(initialValue: config.ollamaBaseURL)
        _ollamaModel = State(initialValue: config.ollamaModel)
        _step = State(initialValue: isReconfiguring ? .configure : .chooseProvider)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                Text(isReconfiguring ? "LLM Settings" : "Connect an AI Provider")
                    .font(.title2)
                    .fontWeight(.semibold)
                if !isReconfiguring {
                    Text("Assistive Control needs an LLM to turn your words into actions.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 28)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)

            Divider()

            // Step content
            Group {
                switch step {
                case .chooseProvider:
                    chooseProviderStep
                case .configure:
                    configureStep
                case .result(let success, let message):
                    resultStep(success: success, message: message)
                }
            }
            .padding(24)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // Pre-fill keys from Keychain.
            anthropicKey = configStore.apiKey(for: .anthropic) ?? ""
            openAIKey    = configStore.apiKey(for: .openai) ?? ""
        }
    }

    // MARK: - Step 1: Choose Provider

    private var chooseProviderStep: some View {
        VStack(spacing: 12) {
            ForEach(LLMProviderType.allCases, id: \.self) { type in
                ProviderCard(
                    type: type,
                    isSelected: selectedProvider == type,
                    action: { selectedProvider = type }
                )
            }

            Spacer(minLength: 16)

            HStack {
                Spacer()
                Button("Continue") {
                    step = .configure
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Step 2: Configure

    private var configureStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !isReconfiguring {
                // Provider picker shown only in reconfiguring mode (already chose in step 1).
                // In onboarding we came from step 1 so selectedProvider is already set.
            }

            // Provider-specific fields.
            switch selectedProvider {
            case .anthropic:
                anthropicFields
            case .openai:
                openAIFields
            case .localOllama:
                ollamaFields
            }

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                if !isReconfiguring {
                    Button("Back") {
                        step = .chooseProvider
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                if isTesting {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 4)
                }
                Button("Test Connection") {
                    Task { await testConnection() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTesting || !canTest)
            }
        }
    }

    private var anthropicFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude (Anthropic)")
                .font(.headline)

            LabeledField(label: "API Key") {
                SecureField("sk-ant-...", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledField(label: "Model") {
                Picker("", selection: $selectedAnthropicModel) {
                    Text("claude-opus-4-6").tag("claude-opus-4-6")
                    Text("claude-sonnet-4-6").tag("claude-sonnet-4-6")
                    Text("claude-haiku-4-5-20251001").tag("claude-haiku-4-5-20251001")
                }
                .labelsHidden()
            }

            Text("Your API key is stored securely in the macOS Keychain and never transmitted elsewhere.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var openAIFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GPT (OpenAI)")
                .font(.headline)

            LabeledField(label: "API Key") {
                SecureField("sk-...", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledField(label: "Model") {
                Picker("", selection: $selectedOpenAIModel) {
                    Text("gpt-4o").tag("gpt-4o")
                    Text("gpt-4o-mini").tag("gpt-4o-mini")
                }
                .labelsHidden()
            }

            Text("Your API key is stored securely in the macOS Keychain and never transmitted elsewhere.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var ollamaFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local Ollama")
                .font(.headline)

            LabeledField(label: "Base URL") {
                TextField("http://localhost:11434", text: $ollamaURL)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledField(label: "Model") {
                TextField("llama3.2", text: $ollamaModel)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Ollama must be running locally before you test the connection. Run `ollama serve` in Terminal.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Step 3: Result

    private func resultStep(success: Bool, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(success ? .green : .red)

            Text(success ? "Connected. You're all set." : "Connection Failed")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                if !success {
                    Button("Try Again") {
                        step = .configure
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                if success {
                    Button("Finish") {
                        applyConfiguration()
                        onFinish()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Validation

    private var canTest: Bool {
        switch selectedProvider {
        case .anthropic:   return !anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openai:      return !openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .localOllama: return !ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && !ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Test Connection

    @MainActor
    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }

        do {
            switch selectedProvider {
            case .anthropic:
                let provider = AnthropicLLMProvider(apiKey: anthropicKey, model: selectedAnthropicModel)
                _ = try await provider.generateIntent(
                    conversation: [LLMMessage(role: .user, content: "ping")],
                    availableActions: []
                )

            case .openai:
                let provider = OpenAILLMProvider(apiKey: openAIKey, model: selectedOpenAIModel)
                _ = try await provider.generateIntent(
                    conversation: [LLMMessage(role: .user, content: "ping")],
                    availableActions: []
                )

            case .localOllama:
                let rawURL = ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let baseURL = URL(string: rawURL),
                      let tagsURL = URL(string: "\(rawURL)/api/tags") else {
                    throw LLMProviderError.malformedResponse("Invalid base URL.")
                }
                _ = baseURL // suppress unused warning
                let (_, response) = try await URLSession.shared.data(from: tagsURL)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw LLMProviderError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
                }
            }

            step = .result(success: true, message: "Successfully connected to \(selectedProvider.displayName).")

        } catch let err as LLMProviderError {
            step = .result(success: false, message: err.localizedDescription)
        } catch {
            step = .result(success: false, message: error.localizedDescription)
        }
    }

    // MARK: - Apply & Save

    private func applyConfiguration() {
        // Persist API keys to Keychain.
        if !anthropicKey.isEmpty { configStore.saveAPIKey(anthropicKey, for: .anthropic) }
        if !openAIKey.isEmpty    { configStore.saveAPIKey(openAIKey, for: .openai) }

        // Update configuration struct.
        configStore.configuration.providerType    = selectedProvider
        configStore.configuration.anthropicModel  = selectedAnthropicModel
        configStore.configuration.openAIModel     = selectedOpenAIModel
        configStore.configuration.ollamaBaseURL   = ollamaURL
        configStore.configuration.ollamaModel     = ollamaModel
        configStore.hasCompletedOnboarding        = true
        configStore.save()
    }
}

// MARK: - Provider Card

private struct ProviderCard: View {
    let type: LLMProviderType
    let isSelected: Bool
    let action: () -> Void

    private var description: String {
        switch type {
        case .anthropic:
            return "Use Claude models via the Anthropic API. Best reasoning quality."
        case .openai:
            return "Use GPT models via the OpenAI API. Wide ecosystem support."
        case .localOllama:
            return "Run open-source models locally via Ollama. Private, no API key needed."
        }
    }

    private var icon: String {
        switch type {
        case .anthropic:   return "sparkle"
        case .openai:      return "cpu"
        case .localOllama: return "desktopcomputer"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(isSelected ? .white : .accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(type.displayName)
                        .font(.headline)
                        .foregroundColor(isSelected ? .white : .primary)
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                }
            }
            .padding(14)
            .background(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - LabeledField

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
            content()
        }
    }
}
