//
//  SettingsView.swift
//  Osier — UI Layer
//
//  Settings: BYOK key management, LLM provider selection, vault registration.
//  API keys are passed directly to BYOKManager — never stored in UserDefaults.
//

import SwiftUI

struct SettingsView: View {

    @EnvironmentObject var coordinator: LLMCoordinator

    @State private var openAIKeyInput:    String = ""
    @State private var anthropicKeyInput: String = ""
    @State private var showOpenAIKey:     Bool   = false
    @State private var showAnthropicKey:  Bool   = false
    @State private var openAIStatus:      KeyStatus = .unknown
    @State private var anthropicStatus:   KeyStatus = .unknown
    @State private var appeared:          Bool   = false

    @StateObject private var vaultWriter = VaultWriter.shared
    @StateObject private var drives      = ExternalDriveMonitor.shared

    enum KeyStatus { case unknown, saved, cleared }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: OsierSpacing.lg) {
                header
                    .padding(.horizontal, OsierSpacing.md)

                providerSection
                    .padding(.horizontal, OsierSpacing.md)

                byokSection
                    .padding(.horizontal, OsierSpacing.md)

                vaultSection
                    .padding(.horizontal, OsierSpacing.md)

                driveSection
                    .padding(.horizontal, OsierSpacing.md)

                aboutSection
                    .padding(.horizontal, OsierSpacing.md)

                Spacer().frame(height: 120)
            }
            .padding(.top, OsierSpacing.lg)
        }
        .background(Color.osierBg.ignoresSafeArea())
        .onAppear {
            refreshKeyStatus()
            withAnimation(.osierSmooth.delay(0.1)) { appeared = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SETTINGS")
                .font(.osierCaption).foregroundStyle(Color.osierAccent).kerning(2.5)
            Text("Configuration")
                .font(.osierTitle).foregroundStyle(Color.osierPrimary)
        }
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        settingsGroup(title: "LLM Provider") {
            VStack(spacing: OsierSpacing.sm) {
                providerRow(
                    label: "Gemma (Local)",
                    subtitle: "On-device · Private · Offline",
                    icon: "cpu.fill",
                    color: .osierAccent,
                    isActive: coordinator.activeProvider == .local
                ) { coordinator.forceLocal() }

                Divider().background(Color.osierDivider)

                providerRow(
                    label: "OpenAI",
                    subtitle: BYOKManager.shared.hasKey(for: .openAI) ? "Key stored" : "No key",
                    icon: "globe",
                    color: BYOKManager.shared.hasKey(for: .openAI) ? .osierGreen : .osierTertiary,
                    isActive: coordinator.activeProvider == .external(.openAI)
                ) {
                    guard BYOKManager.shared.hasKey(for: .openAI) else { return }
                    coordinator.setProvider(.external(.openAI))
                }

                Divider().background(Color.osierDivider)

                providerRow(
                    label: "Anthropic",
                    subtitle: BYOKManager.shared.hasKey(for: .anthropic) ? "Key stored" : "No key",
                    icon: "sparkles",
                    color: BYOKManager.shared.hasKey(for: .anthropic) ? .osierPurple : .osierTertiary,
                    isActive: coordinator.activeProvider == .external(.anthropic)
                ) {
                    guard BYOKManager.shared.hasKey(for: .anthropic) else { return }
                    coordinator.setProvider(.external(.anthropic))
                }
            }
        }
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 10)
        .animation(.osierSpring.delay(0.05), value: appeared)
    }

    private func providerRow(label: String, subtitle: String, icon: String,
                              color: Color, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.osierHeadline).foregroundStyle(Color.osierPrimary)
                    Text(subtitle).font(.osierCaption).foregroundStyle(Color.osierSecondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.osierAccent)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - BYOK Section

    private var byokSection: some View {
        settingsGroup(title: "API Keys") {
            VStack(spacing: OsierSpacing.md) {
                keyRow(
                    provider: .openAI,
                    label: "OpenAI API Key",
                    icon: "key.fill",
                    color: .osierGreen,
                    input: $openAIKeyInput,
                    showKey: $showOpenAIKey,
                    status: $openAIStatus
                )

                Divider().background(Color.osierDivider)

                keyRow(
                    provider: .anthropic,
                    label: "Anthropic API Key",
                    icon: "key.fill",
                    color: .osierPurple,
                    input: $anthropicKeyInput,
                    showKey: $showAnthropicKey,
                    status: $anthropicStatus
                )
            }
        }
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 10)
        .animation(.osierSpring.delay(0.1), value: appeared)
    }

    private func keyRow(provider: ExternalProvider, label: String, icon: String,
                        color: Color, input: Binding<String>,
                        showKey: Binding<Bool>, status: Binding<KeyStatus>) -> some View {
        VStack(alignment: .leading, spacing: OsierSpacing.sm) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.system(size: 13))
                Text(label)
                    .font(.osierHeadline)
                    .foregroundStyle(Color.osierPrimary)
                Spacer()
                if BYOKManager.shared.hasKey(for: provider) {
                    Text("Stored ✓")
                        .font(.osierCaption)
                        .foregroundStyle(Color.osierGreen)
                }
            }

            HStack(spacing: OsierSpacing.sm) {
                Group {
                    if showKey.wrappedValue {
                        TextField("sk-...", text: input)
                    } else {
                        SecureField("sk-...", text: input)
                    }
                }
                .font(.osierMono)
                .foregroundStyle(Color.osierPrimary)
                .tint(Color.osierAccent)
                .padding(OsierSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: OsierRadius.sm)
                        .fill(Color.osierElevated)
                        .overlay(RoundedRectangle(cornerRadius: OsierRadius.sm)
                            .stroke(Color.osierBorder, lineWidth: 1))
                )

                Button { showKey.wrappedValue.toggle() } label: {
                    Image(systemName: showKey.wrappedValue ? "eye.slash" : "eye")
                        .foregroundStyle(Color.osierSecondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: OsierSpacing.sm) {
                Button("Save Key") {
                    do {
                        try BYOKManager.shared.saveKey(input.wrappedValue, for: provider)
                        status.wrappedValue = .saved
                        input.wrappedValue  = ""
                        refreshKeyStatus()
                    } catch { print("[Settings] Key save failed: \(error)") }
                }
                .font(.osierCaption)
                .foregroundStyle(Color.osierAccent)
                .disabled(input.wrappedValue.isEmpty)

                Spacer()

                if BYOKManager.shared.hasKey(for: provider) {
                    Button("Remove") {
                        BYOKManager.shared.deleteKey(for: provider)
                        status.wrappedValue = .cleared
                        refreshKeyStatus()
                    }
                    .font(.osierCaption)
                    .foregroundStyle(Color.osierRed.opacity(0.8))
                }
            }
        }
    }

    // MARK: - Vault Section

    private var vaultSection: some View {
        settingsGroup(title: "Registered Vaults") {
            VStack(spacing: OsierSpacing.sm) {
                if vaultWriter.registeredVaults.isEmpty {
                    Text("No vaults registered. Pick a folder to register it.")
                        .font(.osierBody)
                        .foregroundStyle(Color.osierSecondary)
                } else {
                    ForEach(vaultWriter.registeredVaults) { vault in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(Color.osierPurple)
                            Text(vault.name)
                                .font(.osierHeadline)
                                .foregroundStyle(Color.osierPrimary)
                            Spacer()
                            Button {
                                withAnimation(.osierSnap) {
                                    vaultWriter.removeVault(id: vault.id)
                                }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(Color.osierRed.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 10)
        .animation(.osierSpring.delay(0.15), value: appeared)
    }

    // MARK: - External Drive Section

    private var driveSection: some View {
        settingsGroup(title: "External Hardware") {
            VStack(spacing: OsierSpacing.sm) {
                if drives.connectedVolumes.isEmpty {
                    Label("No drives connected", systemImage: "externaldrive.slash")
                        .font(.osierBody)
                        .foregroundStyle(Color.osierSecondary)
                } else {
                    ForEach(drives.connectedVolumes, id: \.id) { vol in
                        HStack {
                            Image(systemName: "externaldrive.fill")
                                .foregroundStyle(Color.osierAmber)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vol.displayName)
                                    .font(.osierHeadline)
                                    .foregroundStyle(Color.osierPrimary)
                                if let avail = vol.availableCapacity {
                                    Text("\(Int64(avail).formattedBytes) free")
                                        .font(.osierCaption)
                                        .foregroundStyle(Color.osierSecondary)
                                }
                            }
                            Spacer()
                            Circle()
                                .fill(Color.osierGreen)
                                .frame(width: 7, height: 7)
                        }
                    }
                }
            }
        }
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 10)
        .animation(.osierSpring.delay(0.2), value: appeared)
    }

    // MARK: - About Section

    private var aboutSection: some View {
        settingsGroup(title: "About") {
            VStack(alignment: .leading, spacing: OsierSpacing.sm) {
                infoRow("Version",  "1.0.0")
                infoRow("Runtime",  "CoreML · iOS 17+")
                infoRow("Storage",  "On-device · No cloud required")
                infoRow("Privacy",  "Keys stored in Keychain only")
            }
        }
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 10)
        .animation(.osierSpring.delay(0.25), value: appeared)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.osierBody).foregroundStyle(Color.osierSecondary)
            Spacer()
            Text(value).font(.osierMono).foregroundStyle(Color.osierTertiary)
        }
    }

    // MARK: - Settings Group Container

    private func settingsGroup<Content: View>(title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: OsierSpacing.md) {
            Text(title.uppercased())
                .font(.osierCaption)
                .foregroundStyle(Color.osierTertiary)
                .kerning(1.5)

            content()
                .osierCard()
        }
    }

    // MARK: - Helpers

    private func refreshKeyStatus() {
        openAIStatus    = BYOKManager.shared.hasKey(for: .openAI)    ? .saved : .unknown
        anthropicStatus = BYOKManager.shared.hasKey(for: .anthropic) ? .saved : .unknown
    }
}
