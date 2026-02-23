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
        // Sequence is handled separately — it dispatches recursively, not via AX calls directly.
        if intent.intent == "sequence" {
            guard let steps = intent.steps, !steps.isEmpty else {
                return .failure("Sequence contained no steps.")
            }
            for step in steps {
                let result = await execute(step)
                switch result {
                case .success:
                    break
                case .failure(let reason):
                    return .failure("Step '\(step.intent)' failed: \(reason)")
                case .clarification(let question):
                    // Propagate clarification requests out of the sequence.
                    return .clarification(question)
                case .observation:
                    // Observation steps inside a sequence are ignored (sequences are pre-planned).
                    break
                }
                // Pause between steps so the OS can process each action.
                // App launches need extra time to become accessible in the AX tree.
                let delay: Duration = step.intent == "open_application" ? .seconds(1.5) : .milliseconds(300)
                try? await Task.sleep(for: delay)
            }
            logger.info("Sequence executed \(steps.count) step(s) successfully.")
            return .success
        }

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

            case "press_key":
                let key       = intent.parameters["key"] ?? ""
                let modifiers = (intent.parameters["modifiers"] ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let appName   = intent.parameters["application_name"]
                try accessibilityController.pressKey(key: key, modifiers: modifiers, applicationName: appName)

            case "right_click_element":
                let appName = intent.parameters["application_name"] ?? ""
                let label   = intent.parameters["element_label"] ?? ""
                let role    = intent.parameters["role"]
                try accessibilityController.rightClickElement(applicationName: appName, label: label, role: role)

            case "double_click_element":
                let appName = intent.parameters["application_name"] ?? ""
                let label   = intent.parameters["element_label"] ?? ""
                let role    = intent.parameters["role"]
                try accessibilityController.doubleClickElement(applicationName: appName, label: label, role: role)

            case "scroll":
                let appName   = intent.parameters["application_name"] ?? ""
                let direction = intent.parameters["direction"] ?? "down"
                let amount    = Int(intent.parameters["amount"] ?? "3") ?? 3
                let label     = intent.parameters["element_label"]
                try accessibilityController.scrollInElement(
                    applicationName: appName,
                    label: label,
                    direction: direction,
                    amount: amount
                )

            case "move_mouse":
                if let xStr = intent.parameters["x"], let yStr = intent.parameters["y"],
                   let x = Double(xStr), let y = Double(yStr) {
                    try accessibilityController.moveMouse(to: CGPoint(x: x, y: y))
                } else if let appName = intent.parameters["application_name"],
                          let label  = intent.parameters["element_label"] {
                    try accessibilityController.moveMouseToElement(applicationName: appName, label: label)
                } else {
                    throw ExecutionError.executionFailed(
                        "move_mouse requires either (x, y) coordinates or (application_name + element_label)."
                    )
                }

            case "left_click_coordinates":
                let xStr  = intent.parameters["x"] ?? ""
                let yStr  = intent.parameters["y"] ?? ""
                let count = Int(intent.parameters["count"] ?? "1") ?? 1
                guard let x = Double(xStr), let y = Double(yStr) else {
                    throw ExecutionError.executionFailed("left_click_coordinates requires numeric x and y values.")
                }
                try accessibilityController.clickAt(point: CGPoint(x: x, y: y), count: count)

            case "clarify_request":
                let question = intent.parameters["question"] ?? "Can you clarify your request?"
                return .clarification(question)

            case "get_frontmost_app":
                let result = try accessibilityController.queryFrontmostApp()
                return .observation("Frontmost app: \(result)")

            case "get_screen_elements":
                let appName = intent.parameters["application_name"]
                let result = try accessibilityController.queryScreenElements(applicationName: appName)
                return .observation("Screen elements:\n\(result)")

            case "drag":
                if let sxStr = intent.parameters["start_x"], let syStr = intent.parameters["start_y"],
                   let exStr = intent.parameters["end_x"],   let eyStr = intent.parameters["end_y"],
                   let sx = Double(sxStr), let sy = Double(syStr),
                   let ex = Double(exStr), let ey = Double(eyStr) {
                    try accessibilityController.drag(
                        from: CGPoint(x: sx, y: sy),
                        to: CGPoint(x: ex, y: ey)
                    )
                } else if let app  = intent.parameters["application_name"],
                          let from = intent.parameters["from_label"],
                          let to   = intent.parameters["to_label"] {
                    try accessibilityController.dragFromElement(
                        applicationName: app,
                        fromLabel: from,
                        toLabel: to
                    )
                } else {
                    throw ExecutionError.executionFailed("drag: missing coordinate or element parameters.")
                }

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
