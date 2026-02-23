// ContentView.swift
// Primary SwiftUI interface for Assistive Control v1.
//
// UI responsibilities:
//   - Text input and Send button (blocked until Accessibility permission is granted)
//   - Read-only conversation log showing user messages, LLM intent summaries,
//     execution results, and errors
//   - Status indicator: Idle / Processing / Executing / Error
//   - Permission gate: shows prompt with link to System Settings when not granted
//   - Gear icon toolbar button for LLM reconfiguration

import SwiftUI

// MARK: - Notification Names

extension Notification.Name {
    /// Posted (by AppDelegate or SettingsView) to clear the current conversation.
    static let newSession   = Notification.Name("AssistiveControl.newSession")
    /// Posted by AppDelegate menu to open the Settings sheet.
    static let openSettings = Notification.Name("AssistiveControl.openSettings")
}

// MARK: - App Status

enum AppStatus: Equatable {
    case idle
    case processing
    case executing
    case error(String)

    var label: String {
        switch self {
        case .idle:        return "Idle"
        case .processing:  return "Processing"
        case .executing:   return "Executing"
        case .error:       return "Error"
        }
    }

    var color: Color {
        switch self {
        case .idle:        return .secondary
        case .processing:  return .blue
        case .executing:   return .orange
        case .error:       return .red
        }
    }
}

// MARK: - Conversation Entry

struct ConversationEntry: Identifiable {
    enum Kind {
        case userMessage
        case intentSummary
        case executionResult
        case errorMessage
        /// A rephrasing suggestion returned by the LLM when a request is unsupported.
        case suggestion
    }

    let id = UUID()
    let kind: Kind
    let text: String
    let timestamp: Date = .now
}

// MARK: - ViewModel

@MainActor
final class ContentViewModel: ObservableObject {

    @Published var inputText: String = ""
    @Published var conversation: [ConversationEntry] = []
    @Published var status: AppStatus = .idle

    // var (not let) so the provider can be refreshed from the config store on each send.
    var llmProvider: any LLMProvider
    private let registry: ActionRegistry
    private let validator = IntentValidator()
    private let engine: ExecutionEngine
    private let logger = AppLogger(category: "ContentViewModel")

    /// Raw LLM conversation history maintained for multi-turn context.
    private var llmHistory: [LLMMessage] = []

    init(
        llmProvider: any LLMProvider,
        registry: ActionRegistry,
        accessibilityController: AccessibilityControlling
    ) {
        self.llmProvider = llmProvider
        self.registry = registry
        self.engine = ExecutionEngine(
            registry: registry,
            accessibilityController: accessibilityController
        )
    }

    // MARK: - New Session

    /// Clears conversation history and resets state, starting a fresh interaction.
    func startNewSession() {
        conversation.removeAll()
        llmHistory.removeAll()
        status = .idle
        inputText = ""
    }

    // MARK: - Send

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        append(.userMessage, text)
        llmHistory.append(LLMMessage(role: .user, content: text))
        status = .processing

        Task {
            await processUserMessage()
        }
    }

    // MARK: - Processing Pipeline

    private func processUserMessage() async {
        do {
            // Step 1: Generate intent from LLM.
            let rawIntent = try await llmProvider.generateIntent(
                conversation: llmHistory,
                availableActions: registry.availableActions()
            )

            logger.info("Raw intent received: \(rawIntent.intent)")

            // Step 2: Validate.
            let validation = validator.validate(rawIntent)

            switch validation {
            case .unsupported(let message, let suggestion):
                status = .idle
                append(.intentSummary, "Intent: unsupported")
                append(.errorMessage, message)
                if let suggestion = suggestion, !suggestion.isEmpty {
                    append(.suggestion, suggestion)
                }
                appendAssistantHistory("Intent was unsupported: \(message)")

            case .invalid(let error):
                status = .error(error.localizedDescription)
                append(.intentSummary, "Intent: \(rawIntent.intent) (invalid)")
                append(.errorMessage, error.localizedDescription)
                appendAssistantHistory("Validation error: \(error.localizedDescription)")

            case .valid(let intent):
                let summary = intentSummary(for: intent)
                append(.intentSummary, summary)
                status = .executing

                // Step 3: Execute.
                let result = await engine.execute(intent)

                switch result {
                case .success:
                    status = .idle
                    append(.executionResult, "Done.")
                    appendAssistantHistory("Executed: \(intent.intent)")

                case .failure(let reason):
                    status = .error(reason)
                    append(.executionResult, "Failed: \(reason)")
                    appendAssistantHistory("Execution failed: \(reason)")
                }
            }

        } catch let error as LLMProviderError {
            status = .error(error.localizedDescription)
            append(.errorMessage, error.localizedDescription)
            logger.error("LLMProviderError: \(error.localizedDescription)")

        } catch {
            status = .error(error.localizedDescription)
            append(.errorMessage, error.localizedDescription)
            logger.error("Unexpected error: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func append(_ kind: ConversationEntry.Kind, _ text: String) {
        conversation.append(ConversationEntry(kind: kind, text: text))
    }

    private func appendAssistantHistory(_ content: String) {
        llmHistory.append(LLMMessage(role: .assistant, content: content))
    }

    private func intentSummary(for intent: Intent) -> String {
        switch intent.intent {
        case "open_application":
            let id = intent.parameters["bundle_identifier"] ?? "unknown"
            return "Intent: open application (\(id))"
        case "click_element":
            let label = intent.parameters["element_label"] ?? "unknown"
            let app   = intent.parameters["application_name"] ?? "unknown"
            return "Intent: click '\(label)' in \(app)"
        case "type_text":
            let text = intent.parameters["text"] ?? ""
            let preview = String(text.prefix(40))
            let ellipsis = text.count > 40 ? "..." : ""
            return "Intent: type text \"\(preview)\(ellipsis)\""
        case "press_key":
            let key  = intent.parameters["key"] ?? "?"
            let mods = intent.parameters["modifiers"].map { " (\($0))" } ?? ""
            return "Intent: press key \(key)\(mods)"
        case "right_click_element":
            let label = intent.parameters["element_label"] ?? "unknown"
            let app   = intent.parameters["application_name"] ?? "unknown"
            return "Intent: right-click '\(label)' in \(app)"
        case "double_click_element":
            let label = intent.parameters["element_label"] ?? "unknown"
            let app   = intent.parameters["application_name"] ?? "unknown"
            return "Intent: double-click '\(label)' in \(app)"
        case "scroll":
            let dir = intent.parameters["direction"] ?? "down"
            let app = intent.parameters["application_name"] ?? "unknown"
            return "Intent: scroll \(dir) in \(app)"
        case "move_mouse":
            if let x = intent.parameters["x"], let y = intent.parameters["y"] {
                return "Intent: move mouse to (\(x), \(y))"
            }
            let label = intent.parameters["element_label"] ?? "unknown"
            return "Intent: move mouse to '\(label)'"
        case "left_click_coordinates":
            let x = intent.parameters["x"] ?? "?"
            let y = intent.parameters["y"] ?? "?"
            return "Intent: click at (\(x), \(y))"
        case "sequence":
            let count = intent.steps?.count ?? 0
            return "Intent: sequence (\(count) step\(count == 1 ? "" : "s"))"
        default:
            return "Intent: \(intent.intent)"
        }
    }
}

// MARK: - ContentView

struct ContentView: View {

    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var configStore: LLMConfigurationStore
    @StateObject private var viewModel: ContentViewModel

    @State private var showingSettings  = false   // SettingsView
    @State private var showingAIConfig   = false   // OnboardingView (AI provider config)

    init(
        permissionManager: PermissionManager,
        configStore: LLMConfigurationStore,
        registry: ActionRegistry,
        accessibilityController: AccessibilityControlling
    ) {
        self.permissionManager = permissionManager
        self.configStore = configStore
        _viewModel = StateObject(wrappedValue: ContentViewModel(
            llmProvider: configStore.makeProvider(),
            registry: registry,
            accessibilityController: accessibilityController
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Permission gate — shown until Accessibility is granted.
            if !permissionManager.isAccessibilityGranted {
                permissionBanner
            }

            // Conversation log.
            conversationLog

            Divider()

            // Input area + status bar.
            inputArea
        }
        .frame(minWidth: 600, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        // Settings sheet (gear icon or menu bar).
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                configStore: configStore,
                onConfigureAI: {
                    // Dismiss settings, then open the AI config sheet after a beat.
                    showingSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showingAIConfig = true
                    }
                },
                onDismiss: { showingSettings = false }
            )
        }
        // AI provider reconfiguration sheet (opened from SettingsView or directly).
        .sheet(isPresented: $showingAIConfig) {
            OnboardingView(configStore: configStore, isReconfiguring: true) {
                viewModel.llmProvider = configStore.makeProvider()
                showingAIConfig = false
            }
        }
        // First-launch onboarding sheet — auto-dismisses when onboarding completes.
        .sheet(isPresented: Binding(
            get: { !configStore.hasCompletedOnboarding },
            set: { _ in }
        )) {
            OnboardingView(configStore: configStore) {
                // onFinish: hasCompletedOnboarding flips to true, sheet auto-dismisses.
            }
        }
        // New session — clear conversation (posted by SettingsView or menu bar).
        .onReceive(NotificationCenter.default.publisher(for: .newSession)) { _ in
            viewModel.startNewSession()
        }
        // Open settings sheet from menu bar.
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showingSettings = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            permissionManager.checkPermission()
        }
    }

    // MARK: - Subviews

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility Permission Required")
                    .font(.headline)
                Text("Assistive Control needs Accessibility access to automate UI interactions.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                permissionManager.openAccessibilitySettings()
            }
        }
        .padding()
        .background(Color.orange.opacity(0.12))
    }

    private var conversationLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if viewModel.conversation.isEmpty {
                        Text("Type a command below to get started.")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(viewModel.conversation) { entry in
                            ConversationEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.conversation.count) {
                if let last = viewModel.conversation.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Describe what you'd like to do...", text: $viewModel.inputText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .onSubmit {
                        guard canSend else { return }
                        // Refresh provider before send.
                        viewModel.llmProvider = configStore.makeProvider()
                        viewModel.send()
                    }

                Button(action: {
                    // Refresh provider before send so any config changes take effect.
                    viewModel.llmProvider = configStore.makeProvider()
                    viewModel.send()
                }) {
                    Text("Send")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            statusBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.status.color)
                .frame(width: 8, height: 8)
            Text(viewModel.status.label)
                .font(.caption)
                .foregroundColor(viewModel.status.color)
            Spacer()
            Text(configStore.configuration.providerType.displayName)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Helpers

    private var canSend: Bool {
        permissionManager.isAccessibilityGranted &&
        viewModel.status == .idle &&
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Conversation Entry Row

struct ConversationEntryRow: View {
    let entry: ConversationEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.body)
                    .textSelection(.enabled)
                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(suggestionBackground)
        .cornerRadius(entry.kind == .suggestion ? 8 : 0)
        .padding(.vertical, entry.kind == .suggestion ? 2 : 0)
    }

    @ViewBuilder
    private var suggestionBackground: some View {
        if entry.kind == .suggestion {
            Color.blue.opacity(0.10)
        } else {
            Color.clear
        }
    }

    private var icon: some View {
        Group {
            switch entry.kind {
            case .userMessage:
                Image(systemName: "person.circle")
                    .foregroundColor(.accentColor)
            case .intentSummary:
                Image(systemName: "bolt.circle")
                    .foregroundColor(.blue)
            case .executionResult:
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.green)
            case .errorMessage:
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.red)
            case .suggestion:
                Image(systemName: "lightbulb")
                    .foregroundColor(.blue)
            }
        }
        .frame(width: 20)
    }
}
