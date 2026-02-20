# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Assistive Control is a native macOS application enabling users with severe physical disabilities to control macOS by conversing with an LLM. The LLM acts strictly as an **intent planner** — it never executes system commands directly. All execution flows through a validated, risk-classified action registry.

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
 ├── App/          # SwiftUI entry point, ContentView, OnboardingView
 ├── LLM/          # LLMProvider protocol, LocalLLMProvider, AnthropicLLMProvider,
 │                 # OpenAILLMProvider, CloudLLMProvider (stub), LLMConfiguration,
 │                 # LLMConfigurationStore
 ├── Intent/       # Intent model, IntentValidator, ActionRegistry
 ├── Execution/    # RiskLevel, ExecutionEngine, AccessibilityController, PermissionManager
 ├── Voice/        # README only — voice input is a v2 feature
 └── Utilities/    # Logger
```

### Data Flow

User input → `LLMProvider.generateIntent()` → `IntentValidator` → `ActionRegistry` → `ExecutionEngine` → `AccessibilityController` → macOS AXUIElement APIs

### LLM Configuration System

- `LLMConfiguration` — non-sensitive config (provider type, model names, Ollama URL) stored in `UserDefaults`
- `LLMConfigurationStore` — `@MainActor ObservableObject`; owns config persistence, Keychain API key storage, and the `makeProvider()` factory
- `makeProvider()` is called at **send-time** (not at init), so config changes take effect on the next message without restarting the app
- API keys are stored in the macOS Keychain under service `com.assistivecontrol.app`

### Key Architectural Constraints (Non-Negotiable)

- **LLM is planner only.** All LLM output is treated as untrusted input and validated before any action.
- **No shell execution, no `Process()`, no filesystem writes, no dynamic evaluation** — enforce these as hard boundaries.
- **ActionRegistry uses explicit switch-based routing only.** No dynamic dispatch, no reflection.
- **Dependency injection throughout** — no global singletons.
- **Async/await** for all I/O.
- **PermissionManager is the sole owner of Accessibility permission state.** `AccessibilityController` assumes permission is already granted before it is called.

### Intent Schema (v1)

The `Intent` struct is the only output type the LLM may produce:

```swift
struct Intent: Codable {
    let intent: String          // "open_application" | "click_element" | "type_text" | "unsupported"
    let parameters: [String: String]
    let confidence: Double?     // < 0.6 causes validation rejection; nil is allowed
}
```

Supported v1 intents with required parameters:
- `open_application` — `bundle_identifier`
- `click_element` — `application_name`, `element_label`, (optional) `role`
- `type_text` — `text` (max 500 characters; secure fields blocked)

All v1 intents are classified `.harmless`. `.moderate` and `.destructive` throw `ExecutionError.notPermittedInV1`.

### LLM Integration

`LocalLLMProvider` connects to Ollama via `POST /api/chat`. `AnthropicLLMProvider` calls `POST api.anthropic.com/v1/messages` with the system prompt in the top-level `"system"` field (Anthropic API requirement — not in the messages array). `OpenAILLMProvider` calls `POST api.openai.com/v1/chat/completions` with a system message prepended. All three isolate intent decoding in a `decodeIntent(_:)` method for testability.

`CloudLLMProvider` is a legacy stub — superseded by `AnthropicLLMProvider` and `OpenAILLMProvider`.

### Permissions

`PermissionManager` is the single source of truth for Accessibility permission state. It checks at launch and exposes a published property the UI observes to block the Send button until permission is granted.

## Non-Goals (Do Not Implement)

- Voice input (v2)
- File deletion, terminal execution, or any destructive system actions
- Workflow memory or persistent conversation storage
- Adaptive personalization
- Anthropic/OpenAI subscription OAuth (blocked by providers for third-party apps)
