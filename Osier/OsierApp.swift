//
//  OsierApp.swift
//  Osier
//
//  App entry point. Responsibilities:
//  1. Register BGTaskScheduler identifiers BEFORE the first scene connects.
//  2. Boot singleton services (LLMCoordinator, SafetyProtocolEngine).
//  3. Request system permissions on first launch.
//  4. Inject shared environment objects into the view hierarchy.
//

import SwiftUI
import BackgroundTasks

@main
struct OsierApp: App {

    // MARK: - App-Level State

    @StateObject private var coordinator = LLMCoordinator.shared
    @StateObject private var safety      = SafetyProtocolEngine()
    @StateObject private var photoKit    = PhotoKitManager.shared
    @StateObject private var eventKit    = EventKitManager.shared

    // MARK: - Init

    init() {
        // ── Step 1: Register BGTask identifiers ────────────────────────────
        // MUST happen before the app finishes launching (before WindowGroup renders).
        BackupScheduler.registerBackgroundTasks()
    }

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .environmentObject(safety)
                .environmentObject(photoKit)
                .environmentObject(eventKit)
                .task {
                    await bootServices()
                }
        }
    }

    // MARK: - Service Boot

    /// Called once when the root view appears. Requests permissions and
    /// warms up services that need early initialisation.
    private func bootServices() async {
        // ── Step 2: Request PhotoKit permission ────────────────────────────
        await photoKit.requestAuthorization()

        // ── Step 3: Request EventKit permissions ───────────────────────────
        do {
            try await eventKit.requestAllAccess()
        } catch {
            print("[OsierApp] ⚠️ EventKit auth failed: \(error.localizedDescription)")
        }

        // ── Step 4: Restore external drive bookmarks ───────────────────────
        // ExternalDriveMonitor restores on init (already triggered by singleton access).
        _ = ExternalDriveMonitor.shared

        // ── Step 5: Restore vault bookmarks ───────────────────────────────
        _ = VaultWriter.shared

        // ── Step 6: Restore iCloud document query ─────────────────────────
        iCloudDocumentManager.shared.startDiscovery()

        // ── Step 7: Warm up local Gemma (non-blocking — loads in background) ──
        Task.detached(priority: .background) {
            do {
                try await LocalGemmaEngine.shared.loadModel()
            } catch {
                // Model not yet bundled — expected in early development.
                print("[OsierApp] ℹ️ Gemma not loaded: \(error.localizedDescription)")
            }
        }

        // ── Step 8: Set preferred LLM provider ────────────────────────────
        await MainActor.run {
            coordinator.setProvider(LLMProvider.preferred())
        }

        print("[OsierApp] ✅ All services booted.")
    }
}

