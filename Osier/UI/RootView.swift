//
//  RootView.swift
//  Osier — UI Layer
//
//  Three-tab root navigator. Injects all environment objects into tabs.
//  Tab order: Dashboard (primary) · Logs · Settings
//

import SwiftUI

struct RootView: View {

    @EnvironmentObject var coordinator: LLMCoordinator
    @EnvironmentObject var safety:      SafetyProtocolEngine
    @EnvironmentObject var photoKit:    PhotoKitManager
    @EnvironmentObject var eventKit:    EventKitManager

    @State private var selectedTab: Tab = .dashboard

    enum Tab: String { case dashboard, logs, settings }

    var body: some View {
        ZStack(alignment: .bottom) {

            // ── Tab Content ─────────────────────────────────────────────
            TabView(selection: $selectedTab) {

                DashboardView()
                    .tag(Tab.dashboard)

                ServiceLogsView()
                    .tag(Tab.logs)

                SettingsView()
                    .tag(Tab.settings)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))  // manual tab bar below
            .ignoresSafeArea(edges: .bottom)

            // ── Floating CommandBar (always pinned above tab bar) ────────
            VStack(spacing: 0) {
                CommandBarView()
                    .padding(.horizontal, OsierSpacing.md)
                    .padding(.bottom, OsierSpacing.sm)

                // Custom Tab Bar
                customTabBar
                    .padding(.bottom, OsierSpacing.xs)
            }
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) {
                        Divider().opacity(0.3)
                    }
            )

            // ── ConfirmActionCard Overlay ───────────────────────────────
            if safety.isShowingConfirmation, let plan = safety.pendingPlan {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { }  // block pass-through

                ConfirmActionCard(plan: plan, safety: safety)
                    .padding(.horizontal, OsierSpacing.md)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.osierSpring, value: safety.isShowingConfirmation)
        .preferredColorScheme(.dark)
        .background(Color.osierBg.ignoresSafeArea())
    }

    // MARK: - Custom Tab Bar

    private var customTabBar: some View {
        HStack(spacing: 0) {
            tabItem(icon: "square.grid.2x2.fill", label: "Dashboard", tab: .dashboard)
            tabItem(icon: "scroll.fill",          label: "Logs",      tab: .logs)
            tabItem(icon: "gearshape.fill",       label: "Settings",  tab: .settings)
        }
        .padding(.horizontal, OsierSpacing.xl)
        .padding(.vertical, OsierSpacing.sm)
    }

    private func tabItem(icon: String, label: String, tab: Tab) -> some View {
        let active = selectedTab == tab

        return Button {
            withAnimation(.osierSnap) { selectedTab = tab }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: active ? .semibold : .regular))
                    .symbolRenderingMode(active ? .monochrome : .hierarchical)
                    .foregroundStyle(active ? Color.osierAccent : Color.osierTertiary)
                Text(label)
                    .font(.osierCaption)
                    .foregroundStyle(active ? Color.osierAccent : Color.osierTertiary)
            }
            .frame(maxWidth: .infinity)
            .scaleEffect(active ? 1.05 : 1.0)
            .animation(.osierSnap, value: active)
        }
        .buttonStyle(.plain)
    }
}
