# Assistive Control

A native macOS application that lets users with severe physical disabilities control macOS by describing what they want in plain language. An LLM translates the request into a structured intent; a validated action registry executes it via macOS Accessibility APIs.

## How it works

1. User types (or, in v2, speaks) a command — *"Open Safari"*, *"Click the Search button in Finder"*
2. The LLM produces a structured JSON intent — it never executes anything directly
3. `IntentValidator` checks the intent against the action schema and rejects anything malformed or unsupported
4. `ExecutionEngine` routes the validated intent through `AccessibilityController` → AXUIElement APIs

The LLM is a planner only. All execution paths are explicit and auditable.

## Requirements

- macOS 14.0 or later
- Xcode 15+ (to build from source)
- One of the supported LLM backends (see below)
- Accessibility permission granted in System Settings → Privacy & Security → Accessibility

## LLM Backends

Choose one during the onboarding flow (gear icon to reconfigure later):

### Local Ollama — recommended, no API costs

```bash
brew install ollama
ollama pull llama3.2
ollama serve
```

Runs entirely on your machine. No API key, no billing.

### Anthropic (Claude)

Requires an API key from [console.anthropic.com](https://console.anthropic.com). Billed per token.

**Before using:** set a monthly spending limit in Console → Settings → Limits. This caps charges — the API rejects further requests once the limit is reached rather than continuing to bill.

> **Note:** Claude Pro/Max subscriptions cannot be used here. As of January 2026, Anthropic blocks subscription OAuth tokens in all third-party applications at the server level. API keys through the Anthropic Console are the only supported path.

### OpenAI (GPT)

Requires an API key from [platform.openai.com](https://platform.openai.com). Billed per token.

**Before using:** set a monthly budget in Platform → Settings → Limits.

> **Note:** ChatGPT Plus/Pro subscriptions are separate from the OpenAI API and cannot be used for API access.

## Build

```bash
git clone <repo>
cd autonomi
open AssistiveControlApp.xcodeproj
```

Build and run in Xcode. Grant Accessibility permission when prompted.

To build from the command line:

```bash
xcodebuild -project AssistiveControlApp.xcodeproj -scheme AssistiveControlApp build
```

## First Launch

A setup sheet appears automatically on first launch. Select a provider, enter credentials (or configure Ollama), test the connection, and click Finish. The gear icon in the main window reopens this flow at any time.

## Architecture

```
AssistiveControlApp/
 ├── App/          # Entry point, ContentView, OnboardingView
 ├── LLM/          # Provider protocol + LocalLLMProvider, AnthropicLLMProvider,
 │                 # OpenAILLMProvider, LLMConfiguration, LLMConfigurationStore
 ├── Intent/       # Intent model, IntentValidator, ActionRegistry
 ├── Execution/    # ExecutionEngine, AccessibilityController, PermissionManager, RiskLevel
 ├── Voice/        # v2 placeholder
 └── Utilities/    # Logger
```

See `CLAUDE.md` for development guidance and `masterprompt.md` for the full architectural specification.

## Security model

- The LLM never executes actions — all output is treated as untrusted input
- No shell commands (`Process`), no filesystem writes, no dynamic code evaluation
- Action routing is via explicit `switch` statements — no reflection or dynamic dispatch
- API keys are stored in the macOS Keychain, not in `UserDefaults` or on disk
- App Sandbox is disabled (required for cross-app AXUIElement control)

## Status

v1 — supports `open_application`, `click_element`, and `type_text`. All actions are classified `.harmless`. Destructive and moderate risk actions are reserved for v2.
