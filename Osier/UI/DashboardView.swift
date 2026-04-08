//
//  DashboardView.swift
//  Osier — UI Layer
//
//  Primary screen: storage visualization + Action Center quick-action grid.
//  Data is fed from FileSystemManager and ExternalDriveMonitor.
//  Quick actions build ActionPlans directly and queue them in SafetyProtocolEngine.
//

import SwiftUI

// MARK: - Quick Action Definition

struct QuickActionCard: Identifiable {
    let id = UUID()
    let title:    String
    let subtitle: String
    let icon:     String
    let color:    Color
    let build:    () -> ActionPlan
}

// MARK: - DashboardView

struct DashboardView: View {

    @EnvironmentObject var safety:      SafetyProtocolEngine
    @EnvironmentObject var coordinator: LLMCoordinator

    @StateObject private var fileSys = FileSystemManager.shared
    @StateObject private var drives  = ExternalDriveMonitor.shared

    @State private var appeared = false

    // MARK: Quick Actions

    private var quickActions: [QuickActionCard] { [
        QuickActionCard(
            title: "Quick Sort",
            subtitle: "Sort Downloads folder",
            icon: "arrow.up.arrow.down.square.fill",
            color: .osierAccent
        ) {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            return (try? FileActionBuilder.shared.buildPlan(
                from: AgentIntent(kind: .sortFolder(source: downloads, strategy: .byType),
                                  rawCommand: "quick sort downloads"))) ?? emptyPlan("Quick Sort")
        },

        QuickActionCard(
            title: "Quick Move",
            subtitle: "Move to external drive",
            icon: "externaldrive.fill.badge.plus",
            color: .osierAmber
        ) {
            guard let vol = drives.connectedVolumes.first else {
                return emptyPlan("No external drive connected.")
            }
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            return (try? FileActionBuilder.shared.buildPlan(
                from: AgentIntent(kind: .moveFiles(sources: [downloads], destination: vol.rootURL),
                                  rawCommand: "quick move to external"))) ?? emptyPlan("Quick Move")
        },

        QuickActionCard(
            title: "Clear Downloads",
            subtitle: "Trash old downloads",
            icon: "trash.square.fill",
            color: .osierRed
        ) {
            (try? FileActionBuilder.shared.buildPlan(
                from: AgentIntent(kind: .clearDownloads,
                                  rawCommand: "clear downloads"))) ?? emptyPlan("Clear Downloads")
        },

        QuickActionCard(
            title: "Backup Vault",
            subtitle: "Sync to iCloud",
            icon: "icloud.and.arrow.up.fill",
            color: .osierGreen
        ) {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            guard let icloud = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
                return emptyPlan("iCloud unavailable.")
            }
            return (try? FileActionBuilder.shared.buildPlan(
                from: AgentIntent(kind: .backupVault(source: docs, destination: icloud),
                                  rawCommand: "backup vault"))) ?? emptyPlan("Backup Vault")
        }
    ] }

    private func emptyPlan(_ title: String) -> ActionPlan {
        ActionPlan(title: title, summary: "Action unavailable.", actions: [])
    }

    // MARK: - Body

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: OsierSpacing.lg) {
                header
                    .padding(.horizontal, OsierSpacing.md)

                storageSection
                    .padding(.horizontal, OsierSpacing.md)

                actionCenterSection
                    .padding(.horizontal, OsierSpacing.md)

                // Bottom padding for CommandBar
                Spacer().frame(height: 120)
            }
            .padding(.top, OsierSpacing.lg)
        }
        .background(Color.osierBg.ignoresSafeArea())
        .onAppear {
            Task { await fileSys.refreshStorageInfo() }
            Task { await drives.refreshCapacity() }
            withAnimation(.osierSmooth.delay(0.1)) { appeared = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("OSIER")
                    .font(.osierCaption)
                    .foregroundStyle(Color.osierAccent)
                    .kerning(2.5)
                Text("System Agent")
                    .font(.osierDisplay)
                    .foregroundStyle(Color.osierPrimary)
            }
            Spacer()
            StatusDot(color: coordinator.state == .idle ? .osierGreen : .osierAccent,
                      animated: coordinator.state != .idle)
        }
    }

    // MARK: - Storage Section

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: OsierSpacing.md) {
            sectionLabel("Storage")

            // Unified storage ring + bars
            HStack(spacing: OsierSpacing.lg) {
                // Ring
                StorageRingView(
                    internalFraction: fileSys.internalVolume?.usedFraction ?? 0,
                    icloudFraction:   fileSys.icloudVolume?.usedFraction  ?? 0,
                    externalFraction: drives.connectedVolumes.first.map { vol in
                        guard vol.totalCapacity > 0 else { return 0.0 }
                        return Double(vol.totalCapacity - (vol.availableCapacity ?? 0)) / Double(vol.totalCapacity)
                    } ?? 0
                )
                .frame(width: 100, height: 100)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.85)

                // Breakdown bars
                VStack(alignment: .leading, spacing: OsierSpacing.sm) {
                    storageBar(
                        label: "Internal",
                        used:  fileSys.internalVolume?.usedCapacity ?? 0,
                        total: fileSys.internalVolume?.totalCapacity ?? 1,
                        fraction: fileSys.internalVolume?.usedFraction ?? 0,
                        color: .osierAccent
                    )
                    storageBar(
                        label: "iCloud",
                        used:  fileSys.icloudVolume?.usedCapacity ?? 0,
                        total: fileSys.icloudVolume?.totalCapacity ?? 1,
                        fraction: fileSys.icloudVolume?.usedFraction ?? 0,
                        color: .osierGreen
                    )
                    if let ext = drives.connectedVolumes.first {
                        let used = Int64(ext.totalCapacity) - Int64(ext.availableCapacity ?? 0)
                        let frac = ext.totalCapacity > 0 ? Double(used) / Double(ext.totalCapacity) : 0
                        storageBar(label: ext.displayName, used: used, total: Int64(ext.totalCapacity),
                                   fraction: frac, color: .osierAmber)
                    } else {
                        Label("No external drive", systemImage: "externaldrive.slash")
                            .font(.osierCaption)
                            .foregroundStyle(Color.osierTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .osierCard()
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
        }
    }

    private func storageBar(label: String, used: Int64, total: Int64,
                             fraction: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.osierCaption)
                    .foregroundStyle(Color.osierSecondary)
                Spacer()
                Text("\(used.formattedBytes) / \(total.formattedBytes)")
                    .font(.osierMono)
                    .foregroundStyle(Color.osierTertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * fraction, height: 5)
                        .animation(.osierSmooth, value: fraction)
                }
            }
            .frame(height: 5)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.osierCaption)
            .foregroundStyle(Color.osierTertiary)
            .kerning(1.5)
    }

    // MARK: - Action Center

    private var actionCenterSection: some View {
        VStack(alignment: .leading, spacing: OsierSpacing.md) {
            sectionLabel("Action Center")

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: OsierSpacing.sm),
                          GridItem(.flexible(), spacing: OsierSpacing.sm)],
                spacing: OsierSpacing.sm
            ) {
                ForEach(Array(quickActions.enumerated()), id: \.element.id) { index, action in
                    QuickActionButton(card: action) {
                        let plan = action.build()
                        withAnimation(.osierSpring) { safety.queuePlan(plan) }
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                    .animation(.osierSpring.delay(Double(index) * 0.07), value: appeared)
                }
            }
        }
    }
}

// MARK: - Quick Action Button

struct QuickActionButton: View {
    let card:    QuickActionCard
    let onTap:   () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: OsierSpacing.sm) {
                HStack {
                    Image(systemName: card.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(card.color)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.osierTertiary)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.osierHeadline)
                        .foregroundStyle(Color.osierPrimary)
                    Text(card.subtitle)
                        .font(.osierCaption)
                        .foregroundStyle(Color.osierSecondary)
                        .lineLimit(1)
                }
            }
            .padding(OsierSpacing.md)
            .frame(height: 110)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OsierRadius.md)
                    .fill(card.color.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: OsierRadius.md)
                            .stroke(card.color.opacity(0.18), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PressEffect())
    }
}

// MARK: - Storage Ring View

struct StorageRingView: View {
    let internalFraction: Double
    let icloudFraction:   Double
    let externalFraction: Double

    private let lineWidth: CGFloat = 10
    private let gap: Double = 0.03

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: lineWidth)

            // Internal arc (0 → 33%)
            arc(from: 0,    to: 0.33, fill: internalFraction, color: .osierAccent)
            // iCloud arc (35% → 66%)
            arc(from: 0.35, to: 0.66, fill: icloudFraction,   color: .osierGreen)
            // External arc (68% → 99%)
            arc(from: 0.68, to: 0.99, fill: externalFraction, color: .osierAmber)
        }
        .rotationEffect(.degrees(-90))
    }

    private func arc(from start: Double, to end: Double,
                     fill fraction: Double, color: Color) -> some View {
        let span     = end - start
        let fillEnd  = start + span * min(fraction, 1.0)
        return Circle()
            .trim(from: start, to: max(start, fillEnd))
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .animation(.osierSmooth, value: fraction)
    }
}
