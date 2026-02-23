# Assistive Control

A native macOS application that lets users with severe physical disabilities — including paraplegics and quadriplegics — control macOS entirely through natural language. An LLM translates plain-English requests into structured intents; a validated action registry executes them via macOS Accessibility and CGEvent APIs.

The interface is a small floating panel that stays visible above all other apps at all times, so the user never has to switch windows or hunt for the app.

## How it works

1. User types (or, in a future version, speaks) a command — *"Open Chrome and search for the weather"*
2. The LLM produces a structured JSON intent — it never executes anything directly
3. `IntentValidator` checks the intent against the action schema and rejects anything malformed or unsupported
4. `ExecutionEngine` routes the validated intent through `AccessibilityController` → AXUIElement/CGEvent APIs
5. Multi-step commands run automatically as a `sequence` — e.g. "create a new file in Excel" expands to [open Excel → Cmd+N]
6. If execution fails, the error is fed back to the LLM for up to 2 automatic retries with a revised plan
7. When the LLM needs to observe system state first, it issues `get_frontmost_app` or `get_screen_elements` observation intents; results are injected into conversation history and the loop continues

The LLM is a planner only. All execution paths are explicit and auditable. Unsupported requests return a specific rephrasing suggestion rather than a blank error.

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

A setup sheet appears automatically on first launch. Select a provider, enter credentials (or configure Ollama), test the connection, and click Finish. The gear icon in the main panel reopens this flow at any time.

The app lives in your menu bar (`person.wave.2` icon) and does not appear in the Dock.

## Supported Commands

| Intent | Example | Notes |
|---|---|---|
| Open app | "open Safari" / "open my browser" | Uses bundle ID; resolves vague names automatically |
| Click element | "click the OK button in TextEdit" | AX label lookup |
| Type text | "type Hello World" | Max 500 chars |
| Press key | "press Cmd+S" | Supports all modifiers |
| Right-click | "right-click the Desktop" | AX element |
| Double-click | "double-click readme.txt" | AX element |
| Scroll | "scroll down in Safari" | up/down/left/right |
| Click at coords | "click at 200, 400" | Pixel coordinates |
| Move mouse | "move mouse to the close button" | AX element or coords |
| Drag | "drag the file to Documents" | Coordinate or element form |
| Multi-step | "create a new file in Excel" | Runs steps automatically |
| Observe app | "what app is open?" | Queries frontmost app name |
| Observe elements | "click the button in this app" | Lists AX elements, then acts |
| Clarify | "delete the document" (ambiguous) | LLM asks which one |

Confidence below 0.3 returns "unsupported" with a suggestion. Confidence 0.3–0.6 proceeds with a yellow warning shown in the conversation. Failed requests are automatically retried up to 2 times with a revised plan before giving up.

## Conversation UI

| Entry | Icon | Colour | Meaning |
|---|---|---|---|
| User message | person.circle | accent | Your typed input |
| Intent summary | bolt.circle | blue | What the LLM planned |
| Done | checkmark.circle | green | Action succeeded |
| Failed | checkmark.circle | green | Action result with failure reason |
| Error | exclamationmark.triangle | red | Validation or LLM error |
| Suggestion | lightbulb | blue | How to rephrase an unsupported request |
| Clarification | questionmark.bubble | teal | LLM is asking you a question |
| Low confidence | exclamationmark.triangle | yellow | Proceeding with a tentative plan |

Status bar shows: **Idle** · **Processing** (blue) · **Executing** (orange) · **Observing** (purple) · **Error** (red)

## Architecture

```
AssistiveControlApp/
 ├── App/          # Entry point, AppDelegate (menu bar + floating panel),
 │                 # ContentView, OnboardingView
 ├── LLM/          # Provider protocol + LocalLLMProvider, AnthropicLLMProvider,
 │                 # OpenAILLMProvider, LLMConfiguration, LLMConfigurationStore,
 │                 # SystemPrompt (shared prompt builder)
 ├── Intent/       # Intent model, IntentValidator, ActionRegistry
 ├── Execution/    # ExecutionEngine, AccessibilityController, PermissionManager, RiskLevel
 ├── Voice/        # v2 placeholder — voice-to-text input
 └── Utilities/    # Logger
```

See `CLAUDE.md` for development guidance and full architecture details.

## Security model

- The LLM never executes actions — all output is treated as untrusted input
- No shell commands (`Process`), no filesystem writes, no dynamic code evaluation
- Action routing is via explicit `switch` statements — no reflection or dynamic dispatch
- API keys are stored in the macOS Keychain, not in `UserDefaults` or on disk
- App Sandbox is disabled (required for cross-app AXUIElement control)
- All CF type casts from AX APIs are verified with `CFGetTypeID` before use

## Known Issues

- **App becomes unresponsive after an unprocessable request** — when a request results in certain error states (e.g. LLM parse failure, unexpected nil), the app can stop accepting new input. Workaround: use "New Session" from the menu bar to reset state. Fix tracked in v1.1.

## Roadmap

### Next (v1.1)
- [ ] **Fix crash/freeze on error** — app becomes unresponsive after certain unprocessable requests; errors must be caught and the UI must return to `.idle` so new input can be sent
- [ ] Smarter app-launch detection: poll AX tree instead of fixed delay
- [ ] Retry on element-not-found in sequences (3× with back-off)
- [ ] AX tree depth cap to prevent stack overflow on complex apps
- [ ] Address bar auto-focus after opening a browser

### v2 — Voice Input
- [ ] `SFSpeechRecognizer` integration for hands-free command entry
- [ ] Push-to-talk / single-switch activation for users with no hand mobility
- [ ] Optional wake-word detection for fully hands-free control
- [ ] TTS audio feedback ("Opened Chrome", "Pressed Cmd+S")

### v3 — Context Awareness
- [ ] Screenshot + vision LLM for visual element identification
- [ ] Conversation memory across launches
- [ ] Per-app element label hints

### v4 — Personalisation & Safety
- [ ] User-confirmable moderate-risk actions
- [ ] User profiles with saved preferences
- [ ] Append-only audit log
