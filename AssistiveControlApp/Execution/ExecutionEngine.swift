// ExecutionEngine.swift
// Dispatches validated Intents to AccessibilityController via ActionRegistry.
//
// Security invariants:
//   - Only validated Intents reach this layer (IntentValidator runs upstream).
//   - Risk policy is enforced here: .moderate and .destructive throw notPermittedInV1.
//   - All routing is explicit — no arbitrary method execution.
//   - No shell execution, no Process(), no filesystem writes.

import Foundation

/// Orchestrates the execution pipeline for a validated Intent.
///
/// Dependencies are injected for testability:
///   - `registry` provides risk classification and available action descriptors
///   - `accessibilityController` performs the actual AX operations
final class ExecutionEngine {

    private let registry: ActionRegistry
    private let accessibilityController: AccessibilityControlling
    private let logger = AppLogger(category: "ExecutionEngine")

    init(registry: ActionRegistry, accessibilityController: AccessibilityControlling) {
        self.registry = registry
        self.accessibilityController = accessibilityController
    }

    // MARK: - Execution Entry Point

    /// Executes a validated Intent by routing through ActionRegistry and AccessibilityController.
    ///
    /// - Parameter intent: A fully validated Intent (must have passed IntentValidator).
    /// - Returns: ExecutionResult indicating success or failure with a human-readable reason.
    func execute(_ intent: Intent) async -> ExecutionResult {
        logger.info("Executing intent: \(intent.intent)")

        // 1. Look up risk classification.
        guard let risk = registry.riskLevel(for: intent.intent) else {
            logger.error("No registry entry for intent: \(intent.intent)")
            return .failure(ExecutionError.actionNotFound.localizedDescription)
        }

        // 2. Enforce v1 risk policy.
        switch risk {
        case .harmless:
            break // permitted
        case .moderate, .destructive:
            let message = ExecutionError.notPermittedInV1.localizedDescription
            logger.error("Risk policy blocked intent '\(intent.intent)': \(risk)")
            return .failure(message)
        }

        // 3. Dispatch to AccessibilityController via explicit switch.
        //    No dynamic dispatch, no reflection — matches ActionRegistry.riskLevel switch.
        do {
            switch intent.intent {
            case "open_application":
                let bundleID = intent.parameters["bundle_identifier"] ?? ""
                try accessibilityController.openApplication(bundleIdentifier: bundleID)

            case "click_element":
                let appName = intent.parameters["application_name"] ?? ""
                let label   = intent.parameters["element_label"] ?? ""
                let role    = intent.parameters["role"]
                try accessibilityController.clickElement(applicationName: appName, label: label, role: role)

            case "type_text":
                let text = intent.parameters["text"] ?? ""
                try accessibilityController.typeText(text)

            default:
                // Should never reach here — ActionRegistry.riskLevel already gated unknown intents.
                return .failure(ExecutionError.actionNotFound.localizedDescription)
            }

            logger.info("Intent '\(intent.intent)' executed successfully.")
            return .success

        } catch let error as ExecutionError {
            logger.error("ExecutionError for '\(intent.intent)': \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        } catch {
            logger.error("Unexpected error for '\(intent.intent)': \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        }
    }
}
