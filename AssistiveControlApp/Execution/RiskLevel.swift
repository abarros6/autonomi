// RiskLevel.swift
// Risk classification for registered actions.
// Architecture must remain extensible for future moderate/destructive policies.

import Foundation

/// Risk classification for a registered action.
/// v1 policy: only .harmless actions are permitted. .moderate and .destructive
/// throw ExecutionError.notPermittedInV1 at the ExecutionEngine boundary.
enum RiskLevel {
    case harmless
    case moderate
    case destructive
}

// MARK: - Execution Result & Error Types

/// The outcome of an execution attempt.
enum ExecutionResult {
    case success
    case failure(String)
    /// LLM wants to ask the user a question; show it and halt the pipeline.
    case clarification(String)
    /// System query result; inject into LLM history and continue the agent loop.
    case observation(String)
}

/// Typed errors produced by the execution pipeline.
enum ExecutionError: Error, LocalizedError {
    /// The requested action is classified at a risk level not permitted in v1.
    case notPermittedInV1

    /// No action handler was found for the given intent string.
    case actionNotFound

    /// The action handler encountered a runtime failure with a human-readable reason.
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notPermittedInV1:
            return "This action is not permitted in the current version."
        case .actionNotFound:
            return "No handler found for the requested action."
        case .executionFailed(let reason):
            return reason
        }
    }
}
