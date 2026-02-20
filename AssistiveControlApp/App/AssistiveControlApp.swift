// AssistiveControlApp.swift
// SwiftUI app entry point. Wires dependency graph and injects into ContentView.

import SwiftUI

@main
struct AssistiveControlApp: App {

    // PermissionManager is the single source of truth for Accessibility state.
    // It is created at app launch and injected — never a global singleton.
    @StateObject private var permissionManager = PermissionManager()

    // LLMConfigurationStore owns provider selection, non-sensitive config (UserDefaults),
    // and API key storage (Keychain). It also tracks whether onboarding is complete.
    @StateObject private var configStore = LLMConfigurationStore()

    var body: some Scene {
        WindowGroup {
            ContentView(
                permissionManager: permissionManager,
                configStore: configStore,
                registry: ActionRegistry(),
                accessibilityController: AccessibilityController()
            )
            .environmentObject(permissionManager)
            .sheet(isPresented: Binding(
                get: { !configStore.hasCompletedOnboarding },
                set: { _ in }
            )) {
                OnboardingView(configStore: configStore) {
                    // onFinish: sheet auto-dismisses because hasCompletedOnboarding flips to true.
                }
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .commands {
            // Remove standard commands not applicable to an assistive control app.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
