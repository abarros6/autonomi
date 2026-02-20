// PermissionManager.swift
// Single source of truth for Accessibility permission state.
//
// Architecture constraint: No other module checks or requests permission.
// AccessibilityController assumes permission is already granted before any
// of its methods are called. The UI enforces the guard via isAccessibilityGranted.

import AppKit
import ApplicationServices

/// Owns the Accessibility permission lifecycle.
/// Publishes `isAccessibilityGranted` for the UI to observe and block
/// the Send button until permission is in place.
@MainActor
final class PermissionManager: ObservableObject {

    /// True when Accessibility permission is currently granted.
    /// The UI binds to this to prevent ExecutionEngine calls when false.
    @Published private(set) var isAccessibilityGranted: Bool = false

    private let logger = AppLogger(category: "PermissionManager")

    init() {
        checkPermission()
    }

    // MARK: - Permission Check

    /// Checks current Accessibility permission state without triggering a system prompt.
    /// Call this at launch and whenever the app resumes from background.
    func checkPermission() {
        // AXIsProcessTrustedWithOptions: passing nil (or false for kAXTrustedCheckOptionPrompt)
        // checks silently. We never prompt here — the UI presents an explicit call-to-action.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        isAccessibilityGranted = trusted
        logger.info("Accessibility permission: \(trusted ? "granted" : "not granted")")
    }

    // MARK: - System Settings Navigation

    /// Opens System Settings to the Privacy & Security → Accessibility pane
    /// so the user can grant permission. Never attempts to grant permission directly.
    func openAccessibilitySettings() {
        // Security note: this opens a fixed system URL only — no arbitrary URL construction.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
            logger.info("Opened System Settings Accessibility pane.")
        }
    }
}
