// AssistiveControlApp.swift
// SwiftUI app entry point.
//
// Window management is handled entirely by AppDelegate:
//   - A floating NSPanel (always on top, visible across all Spaces) hosts ContentView.
//   - An NSStatusItem in the menu bar provides the sole access point.
//   - The app runs as .accessory (no Dock icon) to minimise clutter for users
//     who may have limited motor control.

import SwiftUI

@main
struct AssistiveControlApp: App {

    // AppDelegate owns the floating panel, status item, and shared objects.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The real window is an NSPanel created by AppDelegate.
        // A Settings scene is required here only to satisfy the App protocol's
        // non-empty body requirement; it presents nothing.
        Settings {
            EmptyView()
        }
    }
}
