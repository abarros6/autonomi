# Voice Input — v2 Feature

Voice input is not implemented in v1.

## Planned v2 Integration

Voice input will be implemented using Apple's native frameworks:

- **AVFoundation** — audio session management and microphone access
- **Speech framework** (`import Speech`) — on-device speech recognition via `SFSpeechRecognizer`

### Architecture Plan

1. A new `VoiceInputController` class will manage the `SFSpeechAudioBufferRecognitionRequest` lifecycle.
2. Recognized text will be injected into the same `ContentViewModel.send()` pipeline used by the text input field — no separate code path.
3. `Info.plist` will require two additional keys:
   - `NSMicrophoneUsageDescription`
   - `NSSpeechRecognitionUsageDescription`
4. A `VoicePermissionManager` (or extension of `PermissionManager`) will own microphone/speech permission state, following the same pattern as the existing Accessibility permission gate.

### Non-Goals for v2 Voice

- Wake-word detection
- Continuous listening mode
- Custom acoustic models
