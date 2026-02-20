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
    case unsupported(String)
}

/// Validates a raw Intent decoded from LLM output.
/// IntentValidator is stateless and dependency-free — inject it wherever needed.
final class IntentValidator {

    private static let maxTextLength = 500
    private static let confidenceThreshold: Double = 0.6

    // MARK: - Supported v1 intents (closed set)

    private static let supportedIntents: Set<String> = [
        "open_application",
        "click_element",
        "type_text",
        "unsupported"
    ]

    // MARK: - Required parameters per intent

    private static let requiredParameters: [String: [String]] = [
        "open_application": ["bundle_identifier"],
        "click_element":    ["application_name", "element_label"],
        "type_text":        ["text"]
    ]

    // MARK: - Validation Entry Point

    /// Validates the intent and returns a typed result.
    /// - Parameter intent: Raw, untrusted Intent from the LLM layer.
    /// - Returns: .valid if all rules pass, .invalid with reason if not, .unsupported if intent == "unsupported".
    func validate(_ intent: Intent) -> ValidationResult {

        // 1. Confidence check (before anything else).
        if let confidence = intent.confidence, confidence < Self.confidenceThreshold {
            return .invalid(.lowConfidence)
        }

        // 2. Handle the "unsupported" sentinel intent gracefully.
        if intent.intent == "unsupported" {
            return .unsupported("The requested action is not supported. Please try rephrasing or describing a different task.")
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

        return .valid(intent)
    }
}
