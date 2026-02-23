// SettingsView.swift
// App settings panel — accessible from the gear icon and from the menu bar.
//
// Sections:
//   General   — Launch at Login toggle
//   Session   — New Session (clear conversation), Quit
//   AI Provider — current provider summary + reconfigure button

import SwiftUI
import ServiceManagement

struct SettingsView: View {

    @ObservedObject var configStore: LLMConfigurationStore

    /// Called when the user wants to open the AI provider reconfiguration flow.
    var onConfigureAI: () -> Void
    /// Called when the sheet should close.
    var onDismiss: () -> Void

    @State private var launchAtLogin: Bool = false
    @State private var loginItemError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    generalSection
                    sessionSection
                    aiProviderSection
                    quitRow
                }
                .padding(20)
            }
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "gearshape.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Button("Done") { onDismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsSection(title: "General") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        applyLaunchAtLogin(launchAtLogin)
                    }
                if let err = loginItemError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                Text("Start Assistive Control automatically when you log in to your Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Session

    private var sessionSection: some View {
        SettingsSection(title: "Session") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Clear the current conversation and start fresh. This does not change your AI provider settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    NotificationCenter.default.post(name: .newSession, object: nil)
                    onDismiss()
                } label: {
                    Label("New Session", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - AI Provider

    private var aiProviderSection: some View {
        SettingsSection(title: "AI Provider") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(configStore.configuration.providerType.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(providerDetail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Configure…") {
                    onConfigureAI()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var providerDetail: String {
        let c = configStore.configuration
        switch c.providerType {
        case .anthropic:   return c.anthropicModel
        case .openai:      return c.openAIModel
        case .localOllama: return "\(c.ollamaModel) · \(c.ollamaBaseURL)"
        }
    }

    // MARK: - Quit row

    private var quitRow: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Text("Quit Assistive Control")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Launch at Login

    private func applyLaunchAtLogin(_ enable: Bool) {
        loginItemError = nil
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert toggle and show a brief error.
            launchAtLogin = !enable
            loginItemError = "Could not update login item: \(error.localizedDescription)"
        }
    }
}

// MARK: - SettingsSection helper

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.leading, 2)

            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
        }
    }
}
