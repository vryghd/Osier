//
//  ServiceLogsView.swift
//  Osier — UI Layer
//
//  Scrollable audit trail of every ActionPlan processed by SafetyProtocolEngine.
//  Displays timestamp, plan title, action items, risk level, and outcome.
//

import SwiftUI

struct ServiceLogsView: View {

    @EnvironmentObject var safety: SafetyProtocolEngine

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LOGS")
                        .font(.osierCaption)
                        .foregroundStyle(Color.osierAccent)
                        .kerning(2.5)
                    Text("Service Audit Trail")
                        .font(.osierTitle)
                        .foregroundStyle(Color.osierPrimary)
                }
                Spacer()
                if !safety.auditLog.isEmpty {
                    Button("Clear") {
                        withAnimation(.osierSnap) {
                            safety.auditLog.removeAll()
                        }
                    }
                    .font(.osierBody)
                    .foregroundStyle(Color.osierRed.opacity(0.8))
                }
            }
            .padding(.horizontal, OsierSpacing.md)
            .padding(.top, OsierSpacing.lg)
            .padding(.bottom, OsierSpacing.md)

            if safety.auditLog.isEmpty {
                emptyState
            } else {
                logList
            }

            Spacer().frame(height: 120)
        }
        .background(Color.osierBg.ignoresSafeArea())
        .onAppear {
            withAnimation(.osierSmooth.delay(0.1)) { appeared = true }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: OsierSpacing.md) {
            Spacer()
            Image(systemName: "scroll")
                .font(.system(size: 44))
                .foregroundStyle(Color.osierTertiary)
            Text("No activity yet")
                .font(.osierHeadline)
                .foregroundStyle(Color.osierSecondary)
            Text("Executed actions will appear here.")
                .font(.osierBody)
                .foregroundStyle(Color.osierTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .opacity(appeared ? 1 : 0)
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: OsierSpacing.sm) {
                ForEach(Array(safety.auditLog.reversed().enumerated()), id: \.element.id) { idx, entry in
                    LogEntryRow(entry: entry)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .animation(.osierSpring.delay(Double(idx) * 0.04), value: appeared)
                }
            }
            .padding(.horizontal, OsierSpacing.md)
        }
    }
}

// MARK: - Log Entry Row

struct LogEntryRow: View {

    let entry: AuditEntry
    @State private var expanded = false

    private var resultColor: Color {
        switch entry.result {
        case .success:              return .osierGreen
        case .partialSuccess:       return .osierAmber
        case .failure:              return .osierRed
        case .cancelledByUser:      return .osierTertiary
        }
    }

    private var resultIcon: String {
        switch entry.result {
        case .success:              return "checkmark.circle.fill"
        case .partialSuccess:       return "exclamationmark.triangle.fill"
        case .failure:              return "xmark.circle.fill"
        case .cancelledByUser:      return "slash.circle.fill"
        }
    }

    private var resultLabel: String {
        switch entry.result {
        case .success(let m):               return m
        case .partialSuccess(let d, let f): return "\(d.count) done · \(f.count) failed"
        case .failure(let e, _):            return e.localizedDescription
        case .cancelledByUser:              return "Cancelled"
        }
    }

    private var timeString: String {
        let fmt = DateFormatter()
        fmt.timeStyle = .medium
        fmt.dateStyle = .short
        return fmt.string(from: entry.timestamp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Summary row
            Button {
                withAnimation(.osierSnap) { expanded.toggle() }
            } label: {
                HStack(spacing: OsierSpacing.sm) {
                    Image(systemName: resultIcon)
                        .foregroundStyle(resultColor)
                        .font(.system(size: 16))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.plan.title)
                            .font(.osierHeadline)
                            .foregroundStyle(Color.osierPrimary)
                            .lineLimit(1)
                        Text(timeString)
                            .font(.osierMono)
                            .foregroundStyle(Color.osierTertiary)
                    }

                    Spacer()

                    riskBadge(entry.plan.overallRisk)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.osierTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(OsierSpacing.md)
            }
            .buttonStyle(.plain)

            // Expanded detail
            if expanded {
                Divider()
                    .background(Color.osierDivider)
                    .padding(.horizontal, OsierSpacing.md)

                VStack(alignment: .leading, spacing: OsierSpacing.sm) {
                    Text(resultLabel)
                        .font(.osierBody)
                        .foregroundStyle(resultColor)

                    ForEach(entry.plan.actions) { action in
                        HStack(spacing: OsierSpacing.xs) {
                            Circle()
                                .fill(riskColor(action.riskLevel))
                                .frame(width: 5, height: 5)
                            Text(action.description)
                                .font(.osierMono)
                                .foregroundStyle(Color.osierSecondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(OsierSpacing.md)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: OsierRadius.md)
                .fill(Color.osierSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: OsierRadius.md)
                        .stroke(Color.osierBorder, lineWidth: 1)
                )
        )
    }

    private func riskBadge(_ risk: RiskLevel) -> some View {
        Text(risk.rawValue.uppercased())
            .font(.osierCaption)
            .foregroundStyle(riskColor(risk))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(riskColor(risk).opacity(0.12))
            )
    }

    private func riskColor(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low:      return .osierGreen
        case .moderate: return .osierAmber
        case .high:     return .osierRed
        }
    }
}
