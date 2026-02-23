// ActionRegistry.swift
// Declares all supported v1 actions and their risk classifications.
//
// Security invariants:
//   - No dynamic dispatch. No reflection. Routing is explicit switch-based only.
//   - Adding a new action requires explicit entries in BOTH descriptors AND riskLevel(for:).
//   - This is the single source of truth for what the system can do.

import Foundation

/// Maps intent strings to ActionDescriptors and RiskLevels.
/// Also serves as the source of available actions passed to the LLM system prompt.
final class ActionRegistry {

    // MARK: - Registered Descriptors

    /// All v1 action descriptors. Order determines system prompt presentation order.
    private let descriptors: [ActionDescriptor] = [
        ActionDescriptor(
            name: "open_application",
            description: "Opens a macOS application by its bundle identifier.",
            requiredParameters: ["bundle_identifier"],
            optionalParameters: []
        ),
        ActionDescriptor(
            name: "click_element",
            description: "Clicks a UI element in a running macOS application, identified by its accessibility label and optional role.",
            requiredParameters: ["application_name", "element_label"],
            optionalParameters: ["role"]
        ),
        ActionDescriptor(
            name: "type_text",
            description: "Types the specified text into the currently focused text field. Maximum 500 characters. Secure/password fields are blocked.",
            requiredParameters: ["text"],
            optionalParameters: []
        ),
        ActionDescriptor(
            name: "press_key",
            description: "Presses a keyboard key with optional modifier keys (cmd, shift, opt, ctrl). Use for shortcuts like Cmd+N, Cmd+S, Escape, Tab, arrow keys, F-keys.",
            requiredParameters: ["key"],
            optionalParameters: ["modifiers", "application_name"]
        ),
        ActionDescriptor(
            name: "right_click_element",
            description: "Right-clicks (secondary click) a UI element in a running macOS application, identified by accessibility label and optional role.",
            requiredParameters: ["application_name", "element_label"],
            optionalParameters: ["role"]
        ),
        ActionDescriptor(
            name: "double_click_element",
            description: "Double-clicks a UI element in a running macOS application, identified by accessibility label and optional role.",
            requiredParameters: ["application_name", "element_label"],
            optionalParameters: ["role"]
        ),
        ActionDescriptor(
            name: "scroll",
            description: "Scrolls in a direction within a running macOS application. Direction must be: up, down, left, or right.",
            requiredParameters: ["application_name", "direction"],
            optionalParameters: ["amount", "element_label"]
        ),
        ActionDescriptor(
            name: "move_mouse",
            description: "Moves the mouse cursor. Provide x and y screen coordinates, OR application_name and element_label to move to a named element.",
            requiredParameters: [],
            optionalParameters: ["x", "y", "application_name", "element_label"]
        ),
        ActionDescriptor(
            name: "left_click_coordinates",
            description: "Clicks at absolute screen pixel coordinates. Use only when the user provides explicit pixel positions or no named element exists. Prefer element-based actions.",
            requiredParameters: ["x", "y"],
            optionalParameters: ["count"]
        ),
        ActionDescriptor(
            name: "sequence",
            description: "Executes an ordered series of actions automatically. Use for multi-step tasks like 'create new file in Excel'. The steps array carries the sub-actions.",
            requiredParameters: [],
            optionalParameters: []
        )
    ]

    // MARK: - Public Interface

    /// Returns all registered descriptors for use in the LLM system prompt.
    func availableActions() -> [ActionDescriptor] {
        descriptors
    }

    /// Returns the descriptor for the given intent name, or nil if not registered.
    func descriptor(for intentName: String) -> ActionDescriptor? {
        descriptors.first { $0.name == intentName }
    }

    /// Returns the risk classification for a registered intent.
    /// Unknown intent names return nil — the caller is responsible for handling that case.
    ///
    /// IMPORTANT: This is a closed switch. Every registered intent must appear here.
    /// If you add an intent to `descriptors`, add it here too.
    func riskLevel(for intentName: String) -> RiskLevel? {
        // Explicit switch — no dynamic dispatch, no reflection.
        switch intentName {
        case "open_application":
            return .harmless
        case "click_element":
            return .harmless
        case "type_text":
            return .harmless
        case "press_key":
            return .harmless
        case "right_click_element":
            return .harmless
        case "double_click_element":
            return .harmless
        case "scroll":
            return .harmless
        case "move_mouse":
            return .harmless
        case "left_click_coordinates":
            return .harmless
        case "sequence":
            return .harmless
        default:
            return nil
        }
    }
}
