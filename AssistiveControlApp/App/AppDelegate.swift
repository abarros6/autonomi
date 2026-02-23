// AppDelegate.swift
// Manages the menu bar status item and the always-visible floating panel.
//
// Design rationale for paraplegic users:
//   The chat panel must stay visible at all times — even when the user is
//   operating Safari, Excel, or any other app. A standard NSWindow would hide
//   behind those apps. Using NSPanel at .floating level with hidesOnDeactivate=false
//   keeps the control interface permanently accessible without requiring the user
//   to switch apps or hunt for the Dock icon.
//
//   The app runs as an .accessory process (no Dock icon) to reduce clutter.
//   The menu bar status icon is the only access point, so it is always available.

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Shared Objects (injected into ContentView)

    // Owned here for the full app lifetime and passed to ContentView by reference.
    let permissionManager = PermissionManager()
    let configStore       = LLMConfigurationStore()

    // MARK: - UI Components

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?

    // Kept as a strong reference so we can update the title before the menu opens.
    private var showHideMenuItem: NSMenuItem?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory so the app does not appear in the Dock or App Switcher.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupFloatingPanel()
    }

    // MARK: - Status Bar Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: "person.wave.2",
                accessibilityDescription: "Assistive Control"
            )
            button.toolTip = "Assistive Control"
        }

        // Build the menu and attach it so clicking the icon shows it directly.
        let menu = buildMenu()
        statusItem?.menu = menu
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        // Show / Hide — label is updated dynamically in menuWillOpen.
        let showHide = NSMenuItem(
            title: "Hide Panel",
            action: #selector(toggleWindow),
            keyEquivalent: ""
        )
        showHide.target = self
        menu.addItem(showHide)
        showHideMenuItem = showHide

        menu.addItem(.separator())

        // New Session
        let newSession = NSMenuItem(
            title: "New Session",
            action: #selector(newSessionAction),
            keyEquivalent: "r"
        )
        newSession.keyEquivalentModifierMask = [.command, .shift]
        newSession.target = self
        menu.addItem(newSession)

        // Settings
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        // Quit
        let quit = NSMenuItem(
            title: "Quit Assistive Control",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)

        return menu
    }

    // MARK: - Floating Panel Setup

    private func setupFloatingPanel() {
        let contentView = ContentView(
            permissionManager: permissionManager,
            configStore: configStore,
            registry: ActionRegistry(),
            accessibilityController: AccessibilityController()
        )

        let hostingController = NSHostingController(rootView: contentView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.title = "Assistive Control"
        panel.contentViewController = hostingController

        // Keep the panel above all regular app windows.
        panel.level = .floating

        // Critical for accessibility use: do NOT hide when another app becomes active.
        // Without this, the panel would vanish every time the user activates their
        // target app, making the tool unusable for someone who cannot easily switch back.
        panel.hidesOnDeactivate = false

        // Visible on all Spaces and in full-screen apps so the user is never stranded.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Prevent accidental dismissal — only the close button or the menu bar hides it.
        panel.isReleasedWhenClosed = false

        panel.center()
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
    }

    // MARK: - Menu Actions

    @objc private func toggleWindow() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    @objc private func newSessionAction() {
        NotificationCenter.default.post(name: .newSession, object: nil)
        // Show the panel so the user can see the cleared conversation.
        if let panel, !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    @objc private func openSettingsAction() {
        // Ensure the panel is visible before presenting the settings sheet.
        if let panel, !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    /// Called just before the menu becomes visible — update dynamic item labels.
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            showHideMenuItem?.title = panel?.isVisible == true ? "Hide Panel" : "Show Panel"
        }
    }
}
