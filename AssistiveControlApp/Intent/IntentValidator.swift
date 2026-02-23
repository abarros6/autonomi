// IntentValidator.swift
// Validates all LLM-produced Intents before execution.
//
// Security invariants:
//   - All LLM output is untrusted. Nothing executes without passing this layer.
//   - Unknown intents are rejected — there is no "pass-through" for unrecognized actions.
//   - Low-confidence intents are rejected to prevent misinterpretation.

import Foundation

/// Validation errors returned by IntentValidator.
enum ValidationError: Error, LocalizedError, Equatable {
    case unknownIntent(String)
    case missingParameter(String)
    case emptyParameter(String)
    case textTooLong(Int)
    case lowConfidence
    case unsupportedIntent

    var errorDescription: String? {
        switch self {
        case .unknownIntent(let name):
            return "Unknown intent '\(name)'. Only supported v1 intents are permitted."
        case .missingParameter(let key):
            return "Required parameter '\(key)' is missing."
        case .emptyParameter(let key):
            return "Required parameter '\(key)' must not be empty."
        case .textTooLong(let count):
            return "Text parameter exceeds the 500-character limit (\(count) characters)."
        case .lowConfidence:
            return "Low confidence — please rephrase your request."
        case .unsupportedIntent:
            return "This request cannot be mapped to a supported action."
        }
    }
}

/// The result of validating an Intent.
enum ValidationResult {
    case valid(Intent)
    case invalid(ValidationError)
    /// The intent was recognised as "unsupported" — inform the user but do not execute.
    /// The optional second value is a suggestion from the LLM on how to rephrase.
    case unsupported(String, String?)
    /// Confidence is 0.3–0.6: proceed with execution but surface a warning to the user.
    case lowConfidenceWarning(Intent, String)
}

/// Validates a raw Intent decoded from LLM output.
/// IntentValidator is stateless and dependency-free — inject it wherever needed.
final class IntentValidator {

    private static let maxTextLength = 500
    private static let confidenceThreshold: Double = 0.3
    private static let confidenceWarningThreshold: Double = 0.6

    // MARK: - Supported v1 intents (closed set)

    private static let supportedIntents: Set<String> = [
        "open_application",
        "click_element",
        "type_text",
        "press_key",
        "right_click_element",
        "double_click_element",
        "scroll",
        "move_mouse",
        "left_click_coordinates",
        "sequence",
        "unsupported",
        "clarify_request",
        "get_frontmost_app",
        "get_screen_elements",
        "drag"
    ]

    // MARK: - Required parameters per intent

    private static let requiredParameters: [String: [String]] = [
        "open_application":      ["bundle_identifier"],
        "click_element":         ["application_name", "element_label"],
        "type_text":             ["text"],
        "press_key":             ["key"],
        "right_click_element":   ["application_name", "element_label"],
        "double_click_element":  ["application_name", "element_label"],
        "scroll":                ["application_name", "direction"],
        "left_click_coordinates": ["x", "y"],
        "clarify_request":       ["question"]
        // move_mouse, sequence, get_frontmost_app, get_screen_elements, and drag
        // have no strictly required params validated via this table (drag has custom logic below)
    ]

    // MARK: - Validation Entry Point

    /// Validates the intent and returns a typed result.
    /// - Parameter intent: Raw, untrusted Intent from the LLM layer.
    /// - Returns: .valid if all rules pass, .invalid with reason if not,
    ///            .unsupported if intent == "unsupported",
    ///            .lowConfidenceWarning if confidence is in the 0.3–0.6 warning band.
    func validate(_ intent: Intent) -> ValidationResult {

        // 1. Confidence check (before anything else).
        if let confidence = intent.confidence {
            if confidence < Self.confidenceThreshold {
                return .invalid(.lowConfidence)
            } else if confidence < Self.confidenceWarningThreshold {
                // Proceed but surface a yellow warning — validate the body first.
                let warning = "Low confidence (\(Int(confidence * 100))%) — proceeding but result may be incorrect."
                let bodyResult = validateBody(intent)
                switch bodyResult {
                case .valid(let i):
                    return .lowConfidenceWarning(i, warning)
                default:
                    return bodyResult
                }
            }
        }

        return validateBody(intent)
    }

    // MARK: - Body Validation (confidence-agnostic)

    /// Validates everything except the confidence threshold.
    /// Extracted so the low-confidence warning branch can reuse the same rules.
    private func validateBody(_ intent: Intent) -> ValidationResult {

        // 2. Handle the "unsupported" sentinel intent gracefully.
        if intent.intent == "unsupported" {
            return .unsupported(
                "The requested action is not supported. Please try rephrasing or describing a different task.",
                intent.suggestion
            )
        }

        // 3. Reject intents not in the supported set.
        guard Self.supportedIntents.contains(intent.intent) else {
            return .invalid(.unknownIntent(intent.intent))
        }

        // 4. Validate required parameters for the specific intent.
        if let required = Self.requiredParameters[intent.intent] {
            for key in required {
                guard let value = intent.parameters[key] else {
                    return .invalid(.missingParameter(key))
                }
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .invalid(.emptyParameter(key))
                }
            }
        }

        // 5. Intent-specific additional rules.
        if intent.intent == "type_text" {
            if let text = intent.parameters["text"], text.count > Self.maxTextLength {
                return .invalid(.textTooLong(text.count))
            }
        }

        // 6. Drag: requires either coordinate form or element form.
        if intent.intent == "drag" {
            let hasCoords = intent.parameters["start_x"] != nil
                         && intent.parameters["start_y"] != nil
                         && intent.parameters["end_x"]   != nil
                         && intent.parameters["end_y"]   != nil
            let hasElements = intent.parameters["application_name"] != nil
                           && intent.parameters["from_label"]       != nil
                           && intent.parameters["to_label"]         != nil
            if !hasCoords && !hasElements {
                return .invalid(.missingParameter(
                    "drag requires either (start_x, start_y, end_x, end_y) or (application_name, from_label, to_label)"
                ))
            }
        }

        // 7. Sequence: validate each step recursively.
        if intent.intent == "sequence" {
            guard let steps = intent.steps, !steps.isEmpty else {
                return .invalid(.missingParameter("steps"))
            }
            for step in steps {
                let stepResult = validate(step)
                switch stepResult {
                case .valid, .lowConfidenceWarning:
                    break
                case .invalid(let err):
                    return .invalid(err)
                case .unsupported:
                    return .invalid(.unsupportedIntent)
                }
            }
        }

        return .valid(intent)
    }
}
