# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Assistive Control is a native macOS application enabling users with severe physical disabilities to control macOS by conversing with an LLM. The LLM acts strictly as an **intent planner** — it never executes system commands directly. All execution flows through a validated, risk-classified action registry.

The full architectural specification lives in `masterprompt.md`.

## Development Environment Requirements

- **Xcode 15 minimum** (Xcode 16 is also acceptable)
- **Swift Language Version: 5.9** — set `SWIFT_VERSION = 5` in Build Settings; do NOT enable Swift 6 strict concurrency
- **macOS 14.0 minimum deployment target**
- **App Sandbox must be disabled** — AXUIElement cross-app control does not work in sandboxed apps. `AssistiveControlApp.entitlements` must have `com.apple.security.app-sandbox` set to `false`
- **`NSAccessibilityUsageDescription`** must be present in `Info.plist`

## Local LLM Setup (Required for Development)

The app connects to a locally running [Ollama](https://ollama.com) instance.

```bash
# Install Ollama (if not already installed)
brew install ollama

# Pull the default model
ollama pull llama3.2

# Start the server (runs on http://localhost:11434 by default)
ollama serve
```

Ollama must be running before launching the app. The base URL and model name are injected into `LocalLLMProvider` — defaults are `http://localhost:11434` and `llama3.2`.

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
 ├── App/          # SwiftUI entry point and ContentView
 ├── LLM/          # LLMProvider protocol + LocalLLMProvider + CloudLLMProvider stub
 ├── Intent/       # Intent model, IntentValidator, ActionRegistry
 ├── Execution/    # RiskLevel, ExecutionEngine, AccessibilityController, PermissionManager
 ├── Voice/        # README only — voice input is a v2 feature
 └── Utilities/    # Logger
```

### Data Flow

User input → `LLMProvider.generateIntent()` → `IntentValidator` → `ActionRegistry` → `ExecutionEngine` → `AccessibilityController` → macOS AXUIElement APIs

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

`LocalLLMProvider` connects to Ollama via `POST /api/chat`. The system prompt is assembled dynamically at call time from the registered `ActionDescriptor` list. Response decoding is isolated in a private `decodeIntent(_:)` method for testability.

`CloudLLMProvider` is a stub conforming to `LLMProvider` — do not implement cloud calls until v2.

### Permissions

`PermissionManager` is the single source of truth for Accessibility permission state. It checks at launch and exposes a published property the UI observes to block the Send button until permission is granted.

## Non-Goals (Do Not Implement)

- Voice input (v2)
- File deletion, terminal execution, or any destructive system actions
- Workflow memory or persistent conversation storage
- Adaptive personalization
- Cloud LLM calls (stub only)
