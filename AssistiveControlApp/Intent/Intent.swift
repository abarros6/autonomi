// Intent.swift
// The sole output type the LLM may produce. All LLM output is untrusted input
// and must pass through IntentValidator before any execution occurs.

import Foundation

/// Structured intent emitted by the LLM after parsing a user request.
/// This is an untrusted value — always validate with IntentValidator before use.
struct Intent: Codable, Equatable {
    /// The action identifier. See Section 7 for supported v1 values.
    let intent: String

    /// Key/value parameters for the action. All values are plain strings.
    let parameters: [String: String]

    /// Model-reported confidence in range 0.0–1.0.
    /// If present and < 0.6, IntentValidator will reject the intent.
    /// If nil, confidence is unknown and validation proceeds normally.
    let confidence: Double?
}
