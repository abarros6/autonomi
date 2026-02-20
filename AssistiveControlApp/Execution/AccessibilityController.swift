// AccessibilityController.swift
// Executes validated, risk-classified actions via macOS AXUIElement APIs.
//
// Architecture constraints:
//   - This class assumes Accessibility permission is already granted.
//     PermissionManager is the sole owner of permission state.
//   - No raw screen coordinate injection without justification.
//   - No arbitrary CGEvent injection.
//   - No shell execution, no Process(), no filesystem writes.
//   - 500-char limit is enforced upstream in IntentValidator;
//     asserted here in debug builds as a defence-in-depth check.

import AppKit
import ApplicationServices

/// Protocol for AccessibilityController, enabling mock injection in tests.
protocol AccessibilityControlling {
    func openApplication(bundleIdentifier: String) throws
    func clickElement(applicationName: String, label: String, role: String?) throws
    func typeText(_ text: String) throws
}

/// Executes AXUIElement actions. Assumes permission is granted before any call.
final class AccessibilityController: AccessibilityControlling {

    private let logger = AppLogger(category: "AccessibilityController")

    // MARK: - Open Application

    /// Launches or activates an application by bundle identifier.
    func openApplication(bundleIdentifier: String) throws {
        logger.info("Opening application: \(bundleIdentifier)")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw ExecutionError.executionFailed("No application found with bundle identifier: \(bundleIdentifier)")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    // MARK: - Click Element

    /// Clicks the first AX element matching `label` (and optionally `role`)
    /// in the named application. Traversal order is AX tree order.
    ///
    /// Ambiguity policy: first match wins (spec Section 12).
    func clickElement(applicationName: String, label: String, role: String?) throws {
        logger.info("Clicking element '\(label)' in '\(applicationName)'")

        guard let app = runningApplication(named: applicationName) else {
            throw ExecutionError.executionFailed("Application '\(applicationName)' is not running.")
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        guard let element = findElement(in: axApp, label: label, role: role) else {
            throw ExecutionError.executionFailed("No element found matching label: \(label)")
        }

        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw ExecutionError.executionFailed("AX press action failed with error code: \(result.rawValue)")
        }
    }

    // MARK: - Type Text

    /// Types text into the currently focused element.
    /// Aborts if the focused element is a secure text field.
    func typeText(_ text: String) throws {
        // Debug-build assertion: the 500-char limit must be enforced upstream.
        assert(text.count <= 500, "typeText called with text exceeding 500 characters — IntentValidator should have rejected this.")

        logger.info("Typing text (\(text.count) chars)")

        // Obtain the system-wide focused element.
        let systemElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard result == .success, let focused = focusedElement else {
            throw ExecutionError.executionFailed("Could not determine focused UI element.")
        }

        // Security guard: refuse to type into secure text fields (passwords, etc.).
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &roleValue)
        // kAXSecureTextFieldRole = "AXSecureTextField" — using the string literal directly
        // because the C constant is not bridged to Swift in all SDK versions.
        if let role = roleValue as? String, role == "AXSecureTextField" {
            throw ExecutionError.executionFailed("Typing into secure fields is not permitted.")
        }

        // Set the value directly via AX.
        let setResult = AXUIElementSetAttributeValue(
            focused as! AXUIElement,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )

        if setResult != .success {
            // Fall back to CGEvent keyboard simulation for elements that don't support AXValue.
            try typeViaKeyEvents(text)
        }
    }

    // MARK: - Private Helpers

    /// Finds the first running application whose localised name matches (case-insensitive).
    private func runningApplication(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Depth-first AX tree search for the first element matching label and optional role.
    private func findElement(in element: AXUIElement, label: String, role: String?) -> AXUIElement? {
        // Check this element.
        if elementMatches(element, label: label, role: role) {
            return element
        }

        // Recurse into children.
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else {
            return nil
        }

        for child in children {
            if let found = findElement(in: child, label: label, role: role) {
                return found
            }
        }

        return nil
    }

    /// Returns true if the element's title or description matches label (case-insensitive)
    /// and its role matches (if role is specified).
    private func elementMatches(_ element: AXUIElement, label: String, role: String?) -> Bool {
        // Check label against AXTitle and AXDescription.
        let labelMatches: Bool = {
            var titleRef: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String,
               title.caseInsensitiveCompare(label) == .orderedSame {
                return true
            }
            var descRef: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef) == .success,
               let desc = descRef as? String,
               desc.caseInsensitiveCompare(label) == .orderedSame {
                return true
            }
            return false
        }()

        guard labelMatches else { return false }

        // If role filter is specified, also check AXRole.
        if let role = role {
            var roleRef: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
                  let elementRole = roleRef as? String,
                  elementRole.caseInsensitiveCompare(role) == .orderedSame
            else {
                return false
            }
        }

        return true
    }

    /// Types text by posting CGEvent key presses for each character.
    /// Used as a fallback when AXValue cannot be set directly.
    private func typeViaKeyEvents(_ text: String) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ExecutionError.executionFailed("Could not create CGEventSource.")
        }

        for scalar in text.unicodeScalars {
            guard scalar.value <= UInt16.max else { continue }
            let char = UniChar(scalar.value)

            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: [char])
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: [char])
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }
}
