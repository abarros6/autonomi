// AssistiveControlApp.swift
// SwiftUI app entry point. Wires dependency graph and injects into ContentView.

import SwiftUI

@main
struct AssistiveControlApp: App {

    // PermissionManager is the single source of truth for Accessibility state.
    // It is created at app launch and injected — never a global singleton.
    @StateObject private var permissionManager = PermissionManager()

    var body: some Scene {
        WindowGroup {
            ContentView(
                permissionManager: permissionManager,
                llmProvider: LocalLLMProvider(),
                registry: ActionRegistry(),
                accessibilityController: AccessibilityController()
            )
            .environmentObject(permissionManager)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .commands {
            // Remove standard commands not applicable to an assistive control app.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
