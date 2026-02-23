# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Assistive Control is a native macOS application enabling users with severe physical disabilities — especially paraplegics who cannot use a keyboard or mouse — to control macOS entirely through natural language. The LLM acts strictly as an **intent planner** — it never executes system commands directly. All execution flows through a validated, risk-classified action registry.

The full architectural specification lives in `masterprompt.md`.

## Development Environment Requirements

- **Xcode 15 minimum** (Xcode 16 / 26.2 beta also acceptable)
- **Swift Language Version: 5.9** — set `SWIFT_VERSION = 5` in Build Settings; do NOT enable Swift 6 strict concurrency
- **macOS 14.0 minimum deployment target**
- **App Sandbox must be disabled** — AXUIElement cross-app control does not work in sandboxed apps. `AssistiveControlApp.entitlements` must have `com.apple.security.app-sandbox` set to `false`
- **`NSAccessibilityUsageDescription`** must be present in `Info.plist`

## xcodegen Gotcha

The project is generated via xcodegen from `project.yml`. Running `xcodegen generate` **resets** both `AssistiveControlApp/Info.plist` and `AssistiveControlApp.entitlements` to empty stubs. After every `xcodegen generate`, restore:

- `Info.plist` — must contain `NSAccessibilityUsageDescription`
- `AssistiveControlApp.entitlements` — must contain `com.apple.security.app-sandbox = false`

## LLM Provider Setup

The app supports three LLM backends, configured at first launch via the onboarding flow (or later via the gear icon):

### Local Ollama (recommended for development — no API costs)

```bash
brew install ollama
ollama pull llama3.2
ollama serve          # runs on http://localhost:11434
```

Ollama must be running before launching the app.

### Anthropic (Claude) — API Key

Obtain a key from [console.anthropic.com](https://console.anthropic.com). Billed per token.

**Important — set a spending limit:** Go to Console → Settings → Limits and set a monthly hard cap before using the app. This prevents unbounded charges; the API rejects requests once the cap is reached rather than continuing to bill.

> **Anthropic OAuth / Pro subscription is not available for third-party apps.** As of January 2026, Anthropic actively blocks subscription OAuth tokens outside Claude Code and Claude.ai (server-side enforcement, not just a TOS note). Any third-party OAuth implementation will receive: *"This credential is only authorized for use with Claude Code."* Do not attempt to implement subscription OAuth in this codebase.

### OpenAI (GPT) — API Key

Obtain a key from [platform.openai.com](https://platform.openai.com). Billed per token. ChatGPT Plus/Pro subscriptions are **not** usable for API access — they are entirely separate billing systems with no OAuth bridge.

**Important — set a spending limit:** Go to Platform → Settings → Limits → Monthly budget before using the app.

## Build & Run

```bash
# Open in Xcode
open AssistiveControlApp.xcodeproj

# Build from command line
xcodebuild -project AssistiveControlApp.xcodeproj -scheme AssistiveControlApp build

# Run tests
xcodebuild -project AssistiveControlApp.xcodeproj -scheme AssistiveControlApp test

# Run a single test class
xcodebuild -project AssistiveControlApp.xcodeproj -scheme AssistiveControlApp test -only-testing:AssistiveControlAppTests/IntentValidatorTests
```

## Architecture

```
AssistiveControlApp/
 ├── App/          # AssistiveControlApp (entry), AppDelegate (menu bar + floating panel),
 │                 # ContentView, OnboardingView
 ├── LLM/          # LLMProvider protocol, LocalLLMProvider, AnthropicLLMProvider,
 │                 # OpenAILLMProvider, CloudLLMProvider (stub), LLMConfiguration,
 │                 # LLMConfigurationStore, SystemPrompt (shared prompt builder)
 ├── Intent/       # Intent model, IntentValidator, ActionRegistry
 ├── Execution/    # RiskLevel, ExecutionEngine, AccessibilityController, PermissionManager
 ├── Voice/        # v3 placeholder — voice-to-text input
 └── Utilities/    # Logger
```

### App Lifecycle & Window Model

The app runs as an `.accessory` process (no Dock icon). All window management is in `AppDelegate`:
- **`NSStatusItem`** — menu bar icon (`person.wave.2`); click to show/hide the panel
- **Floating `NSPanel`** — `level = .floating`, `hidesOnDeactivate = false`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
  - Stays visible above all other apps at all times — critical for paraplegic users who cannot quickly switch back to the app
  - Visible on all Spaces and inside full-screen apps

### Data Flow

User input → `LLMProvider.generateIntent()` → `IntentValidator` → `ActionRegistry` → `ExecutionEngine` → `AccessibilityController` → macOS AXUIElement/CGEvent APIs

### LLM Configuration System

- `LLMConfiguration` — non-sensitive config (provider type, model names, Ollama URL) stored in `UserDefaults`
- `LLMConfigurationStore` — `@MainActor ObservableObject`; owns config persistence, Keychain API key storage, and the `makeProvider()` factory
- `makeProvider()` is called at **send-time** (not at init), so config changes take effect on the next message without restarting the app
- API keys are stored in the macOS Keychain under service `com.assistivecontrol.app`
- `buildSystemPrompt(availableActions:)` in `LLM/SystemPrompt.swift` — shared across all three providers

### Key Architectural Constraints (Non-Negotiable)

- **LLM is planner only.** All LLM output is treated as untrusted input and validated before any action.
- **No shell execution, no `Process()`, no filesystem writes, no dynamic evaluation** — enforce these as hard boundaries.
- **ActionRegistry uses explicit switch-based routing only.** No dynamic dispatch, no reflection.
- **Dependency injection throughout** — no global singletons.
- **Async/await** for all I/O.
- **PermissionManager is the sole owner of Accessibility permission state.** `AccessibilityController` assumes permission is already granted before it is called.
- **Never use force casts (`as!`) on CF types from AX APIs.** Use `CFGetTypeID` checks before casting `AXValue` or `AXUIElement` — conditional `as?` casts always succeed for CF types and do not provide type safety.

### Intent Schema (current)

```swift
struct Intent: Codable, Equatable {
    let intent: String          // see supported intents below
    let parameters: [String: String]
    let confidence: Double?     // < 0.3 → rejected; 0.3–0.6 → lowConfidenceWarning; nil allowed
    let suggestion: String?     // populated by LLM on "unsupported"; shown to user
    let steps: [Intent]?        // populated when intent == "sequence"
}
```

Supported intents and required parameters:
- `open_application` — `bundle_identifier`
- `click_element` — `application_name`, `element_label`, (optional) `role`
- `type_text` — `text` (max 500 chars; secure fields blocked)
- `press_key` — `key`, (optional) `modifiers` (comma-separated: cmd,shift,opt,ctrl), `application_name`
- `right_click_element` — `application_name`, `element_label`, (optional) `role`
- `double_click_element` — `application_name`, `element_label`, (optional) `role`
- `scroll` — `application_name`, `direction` (up/down/left/right), (optional) `amount`, `element_label`
- `move_mouse` — (`x`+`y`) OR (`application_name`+`element_label`)
- `left_click_coordinates` — `x`, `y`, (optional) `count`
- `sequence` — no params; child actions in `steps[]`; auto-executes all steps in order
  - 1.5s delay after `open_application` steps, 300ms between all others
- `clarify_request` — `question`; LLM asks user a question when intent is genuinely ambiguous
- `get_frontmost_app` — no params; returns name of frontmost app as `.observation`
- `get_screen_elements` — (optional) `application_name`; returns AX element list as `.observation`
- `drag` — coordinate form: `start_x`, `start_y`, `end_x`, `end_y`; OR element form: `application_name`, `from_label`, `to_label`

All intents are `.harmless`. `.moderate` / `.destructive` throw `ExecutionError.notPermittedInV1`.

### LLM Integration

`LocalLLMProvider` connects to Ollama via `POST /api/chat`. `AnthropicLLMProvider` calls `POST api.anthropic.com/v1/messages` with the system prompt in the top-level `"system"` field (Anthropic API requirement). `OpenAILLMProvider` calls `POST api.openai.com/v1/chat/completions` with a system message prepended. All three call `buildSystemPrompt(availableActions:)` from `SystemPrompt.swift`.

`CloudLLMProvider` is a legacy stub — superseded by `AnthropicLLMProvider` and `OpenAILLMProvider`.

### Agentic Loop

`ContentViewModel.processUserMessage()` is a retry wrapper (up to 2 retries) around `runAgentLoop()`. The agent loop:
1. Calls `LLMProvider.generateIntent()` to get a plan.
2. Validates with `IntentValidator`.
3. Executes via `ExecutionEngine`, which returns one of four `ExecutionResult` cases:
   - `.success` — done; stop.
   - `.failure(reason)` — feed reason back to LLM and retry (up to 2 times).
   - `.clarification(question)` — show teal bubble to user; stop and wait for reply.
   - `.observation(data)` — inject data into `llmHistory`; loop again (max 5 observations).
4. `AppStatus.observing` (purple) is shown in the status bar during observation steps.

### UI: Conversation Entry Kinds

| Kind | Icon | Background | When used |
|---|---|---|---|
| `.userMessage` | `person.circle` | none | User's typed input |
| `.intentSummary` | `bolt.circle` (blue) | none | Parsed intent label |
| `.executionResult` | `checkmark.circle` (green) | none | "Done." or failure reason |
| `.errorMessage` | `exclamationmark.triangle` (red) | none | Validation / LLM errors |
| `.suggestion` | `lightbulb` (blue) | blue tint | LLM's rephrasing suggestion on unsupported requests |
| `.clarification` | `questionmark.bubble` (teal) | teal tint | LLM asking user a clarifying question |
| `.lowConfidenceWarning` | `exclamationmark.triangle` (yellow) | yellow tint | Confidence 0.3–0.6; proceeding with caveat |

### Permissions

`PermissionManager` is the single source of truth for Accessibility permission state. It checks at launch and exposes a published property the UI observes to block the Send button until permission is granted.

## Roadmap / Open TODOs

### v1.1 — Reliability & Polish (next)
- [ ] **CRITICAL — Fix freeze/crash on error**: When a request results in certain error states (e.g. LLM returns unparseable JSON, network timeout mid-request, or an unexpected `nil` in the pipeline), the app becomes unresponsive and stops accepting new input — the status bar stays stuck on "Error" and the Send button never re-enables. Every code path in `processUserMessage()` / `runAgentLoop()` must guarantee `status` is set back to `.idle` before returning, even on unexpected throws. All error exits should be audited to confirm the UI resets correctly.
- [ ] **Smarter app-launch wait**: Poll the AX tree (up to 5s) instead of a fixed 1.5s delay after `open_application` in sequences
- [ ] **Address bar focus**: After opening Chrome/Safari, explicitly click the address bar (by AX role `AXTextField` + description "Address and search bar") before typing, rather than relying on system focus
- [ ] **AX tree depth cap**: Add recursion depth limit in `findElement` to prevent stack overflow on pathologically deep trees (e.g. Chrome DevTools)
- [ ] **Retry on element-not-found**: In sequences, retry element lookup up to 3× with 500ms back-off before failing
- [ ] **Richer error messages**: Surface the AX error code in failure messages (e.g. `kAXErrorAPIDisabled`, `kAXErrorNotImplemented`)

### v2 — Voice Input
- [ ] **Speech-to-text input**: Integrate macOS `SFSpeechRecognizer` for hands-free command entry — primary input method for users with no hand mobility
- [ ] **Push-to-talk trigger**: Single-switch / switch-access compatible activation (critical for quadriplegic users)
- [ ] **Wake word detection**: Optional always-on detection so users don't need any switch at all
- [ ] **Audio feedback**: TTS confirmation of executed actions ("Opened Chrome", "Typed in search bar")

### v3 — Context Awareness
- [ ] **Screen OCR / vision**: Capture a screenshot and pass it to a vision-capable LLM so it can identify elements by visual appearance rather than AX label
- [ ] **Conversation memory**: Persist recent session history across launches so users don't repeat context
- [ ] **Per-app action hints**: Store learned element labels for common apps (Chrome address bar, etc.) to improve success rate

### v4 — Personalisation & Safety
- [ ] **Moderate-risk actions**: User-confirmable actions (file deletion, form submission)
- [ ] **User profiles**: Saved preferences, frequently-used commands, accessibility needs settings
- [ ] **Audit log**: Append-only log of all executed actions for transparency

## Non-Goals (Do Not Implement)

- File deletion, terminal execution, or any destructive system actions (outside future v4 moderate-risk flow)
- Anthropic/OpenAI subscription OAuth (blocked by providers for third-party apps)
- Dynamic code evaluation or reflection-based dispatch
