//
//  CommandBarView.swift
//  Osier — UI Layer
//
//  Persistent bottom input bar. Primary interface for LLMCoordinator.
//  Shows live status of the agent, displays streaming tokens as they arrive,
//  and fires the command pipeline on submission.
//

import SwiftUI

struct CommandBarView: View {

    @EnvironmentObject var coordinator: LLMCoordinator
    @EnvironmentObject var safety:      SafetyProtocolEngine

    @State private var inputText:     String = ""
    @State private var isFocused:     Bool   = false
    @State private var tokenDisplay:  String = ""
    @FocusState private var fieldFocused: Bool

    // MARK: - Body

    var body: some View {
        VStack(spacing: 6) {
            // Streaming token display
            if !coordinator.streamingBuffer.isEmpty || coordinator.state != .idle {
                streamingStatusRow
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Input bar
            HStack(spacing: OsierSpacing.sm) {
                statusIndicator
                inputField
                sendButton
            }
            .padding(.horizontal, OsierSpacing.md)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: OsierRadius.lg)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: OsierRadius.lg)
                            .stroke(isFocused ? Color.osierBorderFocus : Color.osierBorder,
                                    lineWidth: 1)
                    )
                    .shadow(color: Color.osierAccent.opacity(isFocused ? 0.12 : 0),
                            radius: 12, x: 0, y: 4)
            )
            .animation(.osierSnap, value: isFocused)
        }
        .onChange(of: coordinator.streamingBuffer) { _, new in
            // Show last 60 chars of streaming output
            let trimmed = new.suffix(60)
            withAnimation(.osierSmooth) { tokenDisplay = String(trimmed) }
        }
        .onChange(of: fieldFocused) { _, v in
            withAnimation(.osierSnap) { isFocused = v }
        }
    }

    // MARK: - Streaming Status Row

    private var streamingStatusRow: some View {
        HStack(spacing: OsierSpacing.xs) {
            StatusDot(color: stateColor, animated: coordinator.state == .inferring)

            Text(stateLabel)
                .font(.osierCaption)
                .foregroundStyle(stateColor)

            if !coordinator.streamingBuffer.isEmpty {
                Text("·")
                    .foregroundStyle(Color.osierTertiary)
                Text(tokenDisplay)
                    .font(.osierMono)
                    .foregroundStyle(Color.osierSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            if coordinator.state != .idle {
                Button("Cancel") {
                    coordinator.cancel()
                }
                .font(.osierCaption)
                .foregroundStyle(Color.osierRed)
            }
        }
        .padding(.horizontal, OsierSpacing.sm)
        .animation(.osierSmooth, value: coordinator.streamingBuffer)
    }

    // MARK: - Status Indicator

    private var statusIndicator: some View {
        StatusDot(color: stateColor, animated: coordinator.state == .inferring)
    }

    // MARK: - Input Field

    private var inputField: some View {
        TextField("", text: $inputText, prompt:
            Text("Ask Osier anything…")
                .foregroundStyle(Color.osierTertiary)
        )
        .font(.osierBody)
        .foregroundStyle(Color.osierPrimary)
        .tint(Color.osierAccent)
        .focused($fieldFocused)
        .submitLabel(.send)
        .onSubmit { sendCommand() }
        .disabled(coordinator.state == .inferring || coordinator.state == .executing)
    }

    // MARK: - Send Button

    private var sendButton: some View {
        Button(action: sendCommand) {
            Image(systemName: inputText.isEmpty ? "waveform" : "arrow.up.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(
                    inputText.isEmpty
                        ? Color.osierTertiary
                        : Color.osierAccent
                )
                .symbolEffect(.bounce, value: inputText.isEmpty)
        }
        .buttonStyle(.plain)
        .disabled(inputText.isEmpty || coordinator.state == .inferring)
        .animation(.osierSnap, value: inputText.isEmpty)
    }

    // MARK: - Actions

    private func sendCommand() {
        let cmd = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, coordinator.state == .idle else { return }

        inputText = ""
        fieldFocused = false

        Task {
            await coordinator.process(input: cmd)
        }
    }

    // MARK: - State Helpers

    private var stateColor: Color {
        switch coordinator.state {
        case .idle:             return .osierGreen
        case .inferring:        return .osierAccent
        case .parsing:          return .osierPurple
        case .awaitingConfirm:  return .osierAmber
        case .executing:        return .osierAmber
        case .error:            return .osierRed
        }
    }

    private var stateLabel: String {
        switch coordinator.state {
        case .idle:             return "Ready"
        case .inferring:        return "Thinking…"
        case .parsing:          return "Parsing Command…"
        case .awaitingConfirm:  return "Awaiting Confirmation"
        case .executing:        return "Executing…"
        case .error(let msg):   return "Error: \(msg.prefix(30))"
        }
    }
}
