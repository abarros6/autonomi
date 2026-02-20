// ContentView.swift
// Primary SwiftUI interface for Assistive Control v1.
//
// UI responsibilities:
//   - Text input and Send button (blocked until Accessibility permission is granted)
//   - Read-only conversation log showing user messages, LLM intent summaries,
//     execution results, and errors
//   - Status indicator: Idle / Processing / Executing / Error
//   - Permission gate: shows prompt with link to System Settings when not granted

import SwiftUI

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

    private let llmProvider: LLMProvider
    private let registry: ActionRegistry
    private let validator = IntentValidator()
    private let engine: ExecutionEngine
    private let logger = AppLogger(category: "ContentViewModel")

    /// Raw LLM conversation history maintained for multi-turn context.
    private var llmHistory: [LLMMessage] = []

    init(
        llmProvider: LLMProvider,
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
            case .unsupported(let message):
                status = .idle
                append(.intentSummary, "Intent: unsupported")
                append(.errorMessage, message)
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
            let ellipsis = text.count > 40 ? "…" : ""
            return "Intent: type text \"\(preview)\(ellipsis)\""
        default:
            return "Intent: \(intent.intent)"
        }
    }
}

// MARK: - ContentView

struct ContentView: View {

    @ObservedObject var permissionManager: PermissionManager
    @StateObject private var viewModel: ContentViewModel

    init(
        permissionManager: PermissionManager,
        llmProvider: LLMProvider,
        registry: ActionRegistry,
        accessibilityController: AccessibilityControlling
    ) {
        self.permissionManager = permissionManager
        _viewModel = StateObject(wrappedValue: ContentViewModel(
            llmProvider: llmProvider,
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
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // Re-check permission each time the app comes to the foreground —
            // the user may have granted it in System Settings.
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
                TextField("Describe what you'd like to do…", text: $viewModel.inputText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .onSubmit {
                        guard canSend else { return }
                        viewModel.send()
                    }

                Button(action: { viewModel.send() }) {
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
        .padding(.vertical, 2)
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
            }
        }
        .frame(width: 20)
    }
}
