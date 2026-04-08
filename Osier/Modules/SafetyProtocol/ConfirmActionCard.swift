//
//  ConfirmActionCard.swift
//  Osier — Module D: Safety & Trash Protocol
//
//  The confirmation UI card shown before any mutating action executes.
//  Uses a premium system-utility aesthetic — no chatbot bubble styles.
//

import SwiftUI

struct ConfirmActionCard: View {

    let plan: ActionPlan
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var expandedItems = false

    var body: some View {
        ZStack {
            // Backdrop blur
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(spacing: 0) {

                // MARK: Header
                headerSection

                Divider().background(Color.white.opacity(0.1))

                // MARK: Action List
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(plan.actions) { action in
                            ActionItemRow(action: action)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .frame(maxHeight: 300)

                Divider().background(Color.white.opacity(0.1))

                // MARK: Risk Banner
                riskBanner

                // MARK: Action Buttons
                buttonRow
            }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(riskBorderColor.opacity(0.4), lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 20)
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(riskAccentColor)
                    .font(.title3.weight(.semibold))

                Text("Confirm Action")
                    .font(.headline)
                    .foregroundStyle(.white)

                Spacer()

                // Action count badge
                Text("\(plan.actions.count) step\(plan.actions.count == 1 ? "" : "s")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }

            Text(plan.title)
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text(plan.summary)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.leading)
        }
        .padding(20)
    }

    // MARK: - Risk Banner

    private var riskBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: riskIcon)
                .font(.caption.weight(.bold))
            Text(riskMessage)
                .font(.caption.weight(.medium))
            Spacer()
        }
        .foregroundStyle(riskAccentColor)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(riskAccentColor.opacity(0.12))
    }

    // MARK: - Buttons

    private var buttonRow: some View {
        HStack(spacing: 12) {
            // Cancel
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }

            // Confirm
            Button(action: onConfirm) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Execute")
                }
                .font(.body.weight(.bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(riskAccentColor)
                )
            }
        }
        .padding(20)
    }

    // MARK: - Risk Styling Helpers

    private var riskAccentColor: Color {
        switch plan.overallRisk {
        case .low:      return Color(hue: 0.38, saturation: 0.7, brightness: 0.85)
        case .moderate: return Color(hue: 0.10, saturation: 0.9, brightness: 0.95)
        case .high:     return Color(hue: 0.02, saturation: 0.85, brightness: 0.95)
        }
    }

    private var riskBorderColor: Color { riskAccentColor }

    private var riskIcon: String {
        switch plan.overallRisk {
        case .low:      return "info.circle.fill"
        case .moderate: return "exclamationmark.triangle.fill"
        case .high:     return "exclamationmark.octagon.fill"
        }
    }

    private var riskMessage: String {
        switch plan.overallRisk {
        case .low:      return "Low risk — this action is reversible."
        case .moderate: return "Moderate risk — review steps before confirming."
        case .high:     return "High risk — files will be moved to Trash. 30-day recovery available."
        }
    }
}

// MARK: - Action Item Row

private struct ActionItemRow: View {
    let action: ActionItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            Image(systemName: actionIcon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(actionColor)
                .frame(width: 32, height: 32)
                .background(actionColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(action.type.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(action.description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            // Risk dot
            Circle()
                .fill(riskDotColor)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var actionIcon: String {
        switch action.type {
        case .moveFile, .movePhoto:         return "arrow.right.doc.on.clipboard"
        case .copyFile:                     return "doc.on.doc"
        case .deleteFile, .deletePhoto:     return "trash"
        case .renameFile:                   return "pencil"
        case .createFolder:                 return "folder.badge.plus"
        case .sortFiles:                    return "line.3.horizontal.decrease"
        case .createAlbum:                  return "photo.stack"
        case .createNote, .editNote:        return "note.text"
        case .createEvent:                  return "calendar.badge.plus"
        case .snoozeReminder:               return "bell.slash"
        case .backupVault:                  return "externaldrive.badge.icloud"
        case .exportPDF:                    return "doc.richtext"
        }
    }

    private var actionColor: Color {
        switch action.riskLevel {
        case .low:      return Color(hue: 0.38, saturation: 0.7, brightness: 0.85)
        case .moderate: return Color(hue: 0.10, saturation: 0.9, brightness: 0.95)
        case .high:     return Color(hue: 0.02, saturation: 0.85, brightness: 0.95)
        }
    }

    private var riskDotColor: Color { actionColor }
}

// MARK: - Preview

#Preview {
    let samplePlan = ActionPlan(
        title: "Clear Downloads Folder",
        summary: "Move 14 files to Trash and create an archive folder for recent PDFs.",
        actions: [
            ActionItem(
                type: .deleteFile,
                riskLevel: .high,
                description: "Trash 14 files from /Downloads",
                sourcePath: "/Downloads"
            ),
            ActionItem(
                type: .createFolder,
                riskLevel: .low,
                description: "Create /Documents/Archive/2026",
                destinationPath: "/Documents/Archive/2026"
            ),
            ActionItem(
                type: .moveFile,
                riskLevel: .moderate,
                description: "Move 3 PDFs to new archive folder",
                sourcePath: "/Downloads/report.pdf",
                destinationPath: "/Documents/Archive/2026/report.pdf"
            )
        ]
    )

    ZStack {
        Color(hue: 0.6, saturation: 0.15, brightness: 0.08).ignoresSafeArea()
        ConfirmActionCard(plan: samplePlan, onConfirm: {}, onCancel: {})
    }
}
