# Assistive Control macOS Application – Claude Code Master Prompt

You are building a production-grade macOS assistive control application in Swift.

This application enables users with severe physical disabilities to control macOS by conversing with a Large Language Model (LLM). The LLM is used strictly for intent reasoning. It must never directly execute system commands or access system resources.

This is not a prototype. This must be architected for shipping-quality reliability, safety, and maintainability.

---

# 1. Core Product Constraints (Non-Negotiable)

1. The LLM is a planner only.
2. The application is the executor.
3. The LLM must never:
   - Execute shell commands
   - Spawn processes
   - Access the filesystem
   - Modify system state directly
   - Call OS APIs
4. The LLM may only emit structured JSON that conforms to a strict intent schema.
5. All execution must flow through a risk-classified action registry.
6. The system must be modular so LLM providers can be swapped (local or cloud).
7. All LLM output is untrusted input and must be validated before execution.

---

# 2. Platform

Target platform: macOS (Mac mini).
Minimum deployment target: macOS 14.0.

Use:

- Swift
- SwiftUI
- macOS Accessibility APIs (AXUIElement)
- Native permission request handling

Do NOT use Electron.
Do NOT use Node.
Do NOT use cross-platform abstractions.

This must be a native macOS app.

---

# 3. Development Environment & Project Configuration

## Xcode and Swift version

- **Xcode 15 minimum.** Xcode 16 is also acceptable.
- **Swift Language Version: Swift 5.9.** In Build Settings, set `SWIFT_VERSION = 5`. Do NOT enable Swift 6 strict concurrency — it will produce errors in async/await patterns used throughout this app and is not required for v1.

## App Sandbox (must be disabled)

AXUIElement APIs for controlling other applications are **not available to sandboxed apps**. The sandbox must be disabled. Set `AssistiveControlApp.entitlements` to:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
```

Do not add any other entitlement keys unless explicitly required. Do not re-enable sandboxing.

## Info.plist: Accessibility usage description

Add the following key to `Info.plist`. macOS requires a human-readable explanation before displaying the Accessibility permission prompt:

```xml
<key>NSAccessibilityUsageDescription</key>
<string>Assistive Control needs Accessibility access to automate UI interactions on your behalf.</string>
```

## Local LLM server (Ollama)

The app connects to a locally running Ollama instance for development and v1 deployment. Ollama must be running on the development machine before the app is launched.

Default base URL: `http://localhost:11434`

Default model: `llama3.2` (configurable — do not hardcode beyond the default)

The `LocalLLMProvider` must accept both `baseURL` and `model` as injected configuration, not constants.

---

# 4. High-Level Architecture

Implement the following modular structure:

```
AssistiveControlApp/
 ├── App/
 │    ├── AssistiveControlApp.swift
 │    └── ContentView.swift
 │
 ├── LLM/
 │    ├── LLMProvider.swift
 │    ├── LocalLLMProvider.swift
 │    ├── CloudLLMProvider.swift (stub only)
 │    └── LLMModels.swift
 │
 ├── Intent/
 │    ├── Intent.swift
 │    ├── IntentValidator.swift
 │    └── ActionRegistry.swift
 │
 ├── Execution/
 │    ├── RiskLevel.swift
 │    ├── ExecutionEngine.swift
 │    ├── AccessibilityController.swift
 │    └── PermissionManager.swift
 │
 ├── Voice/
 │    └── README.md (scaffolding only)
 │
 └── Utilities/
      └── Logger.swift
```

Maintain strict separation of concerns. No architectural shortcuts.

---

# 5. Shared Models (Implement First)

Define these types before implementing any other module. Both the LLM layer and the Intent layer depend on them.

## Intent

```swift
struct Intent: Codable {
    let intent: String          // See Section 7 for supported values
    let parameters: [String: String]
    let confidence: Double?     // See Section 8 for validation rules
}
```

## ActionDescriptor

```swift
struct ActionDescriptor: Codable {
    let name: String                       // Matches Intent.intent string
    let description: String                // Human-readable description of the action
    let requiredParameters: [String]       // Parameter keys that must be present
    let optionalParameters: [String]       // Parameter keys that may be present
}
```

`ActionDescriptor` is used by the `ActionRegistry` to declare available actions and by `LocalLLMProvider` to dynamically assemble the system prompt. Every entry in the registry must have a corresponding `ActionDescriptor`.

---

# 6. LLM Abstraction Layer

Define:

```swift
protocol LLMProvider {
    func generateIntent(
        conversation: [LLMMessage],
        availableActions: [ActionDescriptor]
    ) async throws -> Intent
}
```

## LocalLLMProvider

- Accept injected `baseURL: URL` and `model: String` (do not hardcode).
- Assemble the system prompt dynamically at call time (see Section 15).
- Send requests to the Ollama `/api/chat` endpoint using the request/response contract in Section 6a below.
- Decode the raw model output string into `Intent` using a private internal function `decodeIntent(_ raw: String) throws -> Intent`. This function must be independently testable — do not inline it.
- Reject any output that fails JSON parsing.
- On parse failure: surface a structured error to the caller. Do not retry automatically.

### Section 6a: Ollama `/api/chat` API Contract

**Endpoint:** `POST {baseURL}/api/chat`

**Request body:**

```json
{
  "model": "<model name>",
  "stream": false,
  "messages": [
    { "role": "system", "content": "<assembled system prompt>" },
    { "role": "user",   "content": "<user message>" }
  ]
}
```

The `messages` array is built from `conversation: [LLMMessage]`. Prepend the assembled system prompt as a `system` role message.

**Response body (success):**

```json
{
  "model": "llama3.2",
  "message": {
    "role": "assistant",
    "content": "{\"intent\": \"open_application\", \"parameters\": {\"bundle_identifier\": \"com.apple.safari\"}, \"confidence\": 0.95}"
  },
  "done": true
}
```

Extract `response.message.content` as the raw string. Pass it to `decodeIntent(_:)` to produce an `Intent`. If `done` is `false` or the field is missing, treat the response as malformed and throw a parse error.

**Error response:** Any non-2xx HTTP status code must throw a typed networking error with the status code included.

## CloudLLMProvider

- Stub implementation only.
- Must conform to `LLMProvider` protocol.
- Do not implement actual cloud calls yet.

---

# 7. Strict Intent Schema

Supported v1 intents ONLY:

1. `open_application`
   Required parameters:
   - `bundle_identifier`

2. `click_element`
   Required parameters:
   - `application_name`
   - `element_label`
   Optional:
   - `role`

3. `type_text`
   Required:
   - `text` (maximum 500 characters; see Section 8 for enforcement)

4. `unsupported`
   No parameters required. Used when the request cannot be mapped to a known intent.

No other intents allowed in v1.

---

# 8. Intent Validation

Implement `IntentValidator` that:

- Rejects unknown intent types
- Verifies all required parameters are present and non-empty
- Rejects malformed or empty parameters
- Enforces `type_text` character limit: reject if `text` exceeds 500 characters
- Returns structured validation errors

### Confidence threshold

If `Intent.confidence` is present and is less than `0.6`, `IntentValidator` must reject the intent and return a validation error with message: `"Low confidence — please rephrase your request."` Do not execute uncertain intents.

If `confidence` is `nil`, treat it as unknown and allow execution to proceed normally.

If intent == `"unsupported"`, it must be handled gracefully — log it and return a user-visible message explaining the action is not supported.

---

# 9. Risk Classification

Define:

```swift
enum RiskLevel {
    case harmless
    case moderate
    case destructive
}
```

For v1: All supported intents (`open_application`, `click_element`, `type_text`) are `.harmless`.

Any intent classified `.moderate` or `.destructive` must throw `ExecutionError.notPermittedInV1` and surface the message: `"This action is not permitted in the current version."` Do not silently ignore these cases.

The architecture must remain extensible for future moderate and destructive enforcement policies.

---

# 10. Action Registry

Create an `ActionRegistry` that:

- Stores the set of registered `ActionDescriptor` values (used to populate `availableActions` when calling the LLM)
- Maps each intent string to a `RiskLevel` and an explicit execution handler

No dynamic dispatch.
No reflection.
Use explicit switch-based routing.

`ActionRegistry` must expose a method to retrieve all `[ActionDescriptor]` values for passing to `LLMProvider.generateIntent`.

---

# 11. Execution Engine

`ExecutionEngine` responsibilities:

1. Accept validated `Intent`
2. Look up action in `ActionRegistry`
3. Enforce risk policy (see Section 9)
4. Call appropriate method in `AccessibilityController`
5. Return structured result

Define:

```swift
enum ExecutionError: Error {
    case notPermittedInV1
    case actionNotFound
    case executionFailed(String)
}

enum ExecutionResult {
    case success
    case failure(String)
}
```

Never allow arbitrary method execution.

---

# 12. AccessibilityController

`AccessibilityController` assumes Accessibility permission has already been granted before any of its methods are called. It does not check or request permission — that is `PermissionManager`'s sole responsibility.

Implement:

```swift
func openApplication(bundleIdentifier: String) throws
func clickElement(applicationName: String, label: String, role: String?) throws
func typeText(_ text: String) throws
```

Use AXUIElement APIs.

Do NOT:
- Use raw screen coordinates unless unavoidable
- Inject arbitrary CGEvents without reason

### `clickElement` ambiguity policy

If multiple AX elements match `element_label` (and optionally `role`), select the **first match in AX tree traversal order**. If zero elements match, throw a structured error: `ExecutionError.executionFailed("No element found matching label: \(label)")`.

### `typeText` safety constraints

Before typing, check whether the currently focused AX element has the role `kAXSecureTextField`. If it does, abort and throw `ExecutionError.executionFailed("Typing into secure fields is not permitted.")`. The 500-character limit is enforced upstream in `IntentValidator` — do not duplicate the check here, but assert it in debug builds.

---

# 13. PermissionManager

`PermissionManager` is the single owner of Accessibility permission state. No other module checks or requests permission.

Must:

- Check Accessibility permission at app launch
- Expose a published `Bool` property indicating whether permission is currently granted
- Provide a method to open System Settings to the Accessibility pane
- Block all `ExecutionEngine` calls until permission is granted (the UI enforces this via the published state)

Never attempt automation without permission.

---

# 14. SwiftUI Interface (v1)

Implement minimal but structured UI:

- Text input field
- "Send" button
- Read-only conversation log (displays user messages, LLM intent summaries, execution results, and errors)
- Status indicator:
  - Idle
  - Processing
  - Executing
  - Error

Do NOT implement voice input yet.

Create `Voice/README.md` describing future integration plan using AVFoundation and speech recognition APIs.

---

# 15. LLM System Prompt (Assembled Dynamically in LocalLLMProvider)

The system prompt is **assembled at call time** by serializing the `availableActions: [ActionDescriptor]` array into a JSON block appended to the base instruction. This ensures the LLM always knows the exact current schema.

### Base instruction (hardcoded):

```
You are an intent parser for a macOS assistive control system. You must output ONLY valid JSON matching the provided schema. Do not include prose. Do not include explanations. Only return JSON. If the request cannot be mapped to a supported intent, return: {"intent": "unsupported", "parameters": {}}.
```

### Dynamic schema block (appended after the base instruction):

The available actions are serialized as a JSON array and appended to the system message in this format:

```
Available actions:
[
  {
    "name": "open_application",
    "description": "Opens a macOS application by bundle identifier.",
    "requiredParameters": ["bundle_identifier"],
    "optionalParameters": []
  },
  ...
]

Output must conform to: {"intent": "<name>", "parameters": {"<key>": "<value>"}, "confidence": <0.0-1.0>}
```

Reject any response that does not decode cleanly into `Intent`.

---

# 16. Security Invariants

Enforce in code:

- No shell execution
- No `Process()` usage
- No filesystem writes
- No dynamic evaluation
- No arbitrary external network calls (except configured LLM endpoint)
- No privilege escalation

All LLM output is untrusted input.

---

# 17. Non-Goals (Do Not Implement)

- Voice input
- File deletion
- Terminal execution
- Workflow memory
- Persistent conversation storage
- Adaptive personalization

---

# 18. Implementation Order

Follow this order strictly. Each step depends on all prior steps.

1. Create project structure and configure entitlements, `Info.plist`, and build settings (see Section 3)
2. Implement shared models: `Intent`, `ActionDescriptor`, `RiskLevel`, `ExecutionResult`, `ExecutionError`
3. Implement `LLMProvider` protocol and `LLMMessage` type
4. Implement `ActionRegistry` (defines registered `ActionDescriptor` values and routing)
5. Implement `LocalLLMProvider` (depends on `ActionDescriptor` from step 4)
6. Implement `IntentValidator`
7. Implement `PermissionManager`
8. Implement `AccessibilityController`
9. Implement `ExecutionEngine`
10. Wire SwiftUI interface
11. Add structured logging
12. Write unit tests (see Section 19)

---

# 19. Testing Requirements

Write XCTest unit tests covering:

- `IntentValidator`: test each supported intent, missing parameters, unknown intents, `confidence` threshold boundary, `type_text` length limit
- `ActionRegistry`: verify correct `RiskLevel` returned per intent, verify `notPermittedInV1` thrown for unsupported risk levels
- `ExecutionEngine`: use a mock `LLMProvider` conformance and a mock `AccessibilityController` to test the full dispatch path without touching real APIs
- `LocalLLMProvider.decodeIntent`: test valid JSON, malformed JSON, missing fields, prose-only response

Place tests in `AssistiveControlAppTests/`.

---

# 20. Code Quality Requirements

- Use async/await
- Use dependency injection
- No global singletons
- Clear module separation
- Public interfaces documented
- Security boundaries commented clearly

---

Generate the complete project scaffolding and core implementation for v1 following the architecture above.

Do not simplify architecture.
Do not collapse modules.
Do not remove safety layers.

This is assistive technology and must be engineered accordingly.
