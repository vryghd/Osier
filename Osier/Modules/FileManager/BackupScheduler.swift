//
//  BackupScheduler.swift
//  Osier — Module A: File & Hardware Manager
//
//  Manages background sync jobs using BackgroundTasks framework.
//  Supports two job types:
//    1. iCloud sync — copies specified folders to iCloud Drive
//    2. External drive sync — copies to a bookmarked external volume
//
//  Background tasks must be registered at app launch (before the app finishes
//  launching). Task identifiers must be declared in Info.plist under
//  BGTaskSchedulerPermittedIdentifiers.
//
//  Info.plist entries required:
//    com.osier.backup.icloud
//    com.osier.backup.external
//

import Foundation
import BackgroundTasks

// MARK: - Backup Job

struct BackupJob: Codable, Identifiable {
    let id: UUID
    let name: String
    let sourceBookmark: Data      // Security-scoped bookmark of source folder
    let destinationBookmark: Data // Security-scoped bookmark of destination
    let kind: Kind
    var intervalSeconds: TimeInterval  // How often to run (e.g., 3600 = hourly)
    var lastRunAt: Date?
    var nextRunAt: Date?

    enum Kind: String, Codable {
        case iCloud
        case external
    }
}

// MARK: - Backup Result

struct BackupResult {
    let jobID: UUID
    let startedAt: Date
    let completedAt: Date
    let filesCopied: Int
    let bytesTransferred: Int64
    let errors: [Error]

    var succeeded: Bool { errors.isEmpty }
}

// MARK: - BackupScheduler

@MainActor
final class BackupScheduler: ObservableObject {

    // MARK: - Published State

    @Published var scheduledJobs: [BackupJob] = []
    @Published var lastResults: [UUID: BackupResult] = [:]
    @Published var isRunning: Bool = false

    // MARK: - Singleton

    static let shared = BackupScheduler()
    private init() {
        loadJobs()
    }

    private let jobsStorageKey = "osier.backup.jobs"
    private let fm = FileManager.default

    // MARK: - BGTask Identifiers

    static let iCloudTaskID   = "com.osier.backup.icloud"
    static let externalTaskID = "com.osier.backup.external"

    // MARK: - Registration (call from App @main, before scene connects)

    /// Must be called from AppDelegate/App init before launch completes.
    static func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: iCloudTaskID,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            BackupScheduler.handleBackgroundTask(processingTask, kind: .iCloud)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: externalTaskID,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            BackupScheduler.handleBackgroundTask(processingTask, kind: .external)
        }

        print("[BackupScheduler] ✅ Background tasks registered.")
    }

    // MARK: - Background Task Handler

    private static func handleBackgroundTask(_ task: BGProcessingTask, kind: BackupJob.Kind) {
        let scheduler = BackupScheduler.shared

        task.expirationHandler = {
            print("[BackupScheduler] ⚠️ Background task expired before completion.")
            task.setTaskCompleted(success: false)
        }

        Task {
            let jobs = scheduler.scheduledJobs.filter { $0.kind == kind }
            for var job in jobs {
                do {
                    let result = try await scheduler.execute(job: job)
                    await MainActor.run {
                        scheduler.lastResults[job.id] = result
                        job.lastRunAt = result.completedAt
                        scheduler.updateJob(job)
                    }
                } catch {
                    print("[BackupScheduler] ❌ Job \(job.name) failed: \(error)")
                }
            }
            task.setTaskCompleted(success: true)
            await scheduler.scheduleNextRun(kind: kind)
        }
    }

    // MARK: - Job Management

    func addJob(_ job: BackupJob) {
        scheduledJobs.append(job)
        saveJobs()
        Task { await scheduleNextRun(kind: job.kind) }
        print("[BackupScheduler] ➕ Job added: \(job.name)")
    }

    func removeJob(id: UUID) {
        scheduledJobs.removeAll { $0.id == id }
        saveJobs()
        print("[BackupScheduler] 🗑 Job removed: \(id)")
    }

    func updateJob(_ job: BackupJob) {
        if let idx = scheduledJobs.firstIndex(where: { $0.id == job.id }) {
            scheduledJobs[idx] = job
            saveJobs()
        }
    }

    // MARK: - Manual Run

    /// Runs a specific job immediately (foreground).
    func runNow(job: BackupJob) async throws -> BackupResult {
        isRunning = true
        defer { isRunning = false }

        let result = try await execute(job: job)
        lastResults[job.id] = result

        var updated = job
        updated.lastRunAt = result.completedAt
        updateJob(updated)

        return result
    }

    // MARK: - Execution Engine

    private func execute(job: BackupJob) async throws -> BackupResult {
        let startedAt = Date()
        var filesCopied = 0
        var bytesTransferred: Int64 = 0
        var errors: [Error] = []

        // Resolve source
        var staleSource = false
        let sourceURL = try URL(
            resolvingBookmarkData: job.sourceBookmark,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &staleSource
        )

        // Resolve destination
        var staleDest = false
        let destURL = try URL(
            resolvingBookmarkData: job.destinationBookmark,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &staleDest
        )

        if staleSource || staleDest {
            throw BackupError.staleBookmark
        }

        let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
        let destAccess   = destURL.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
            if destAccess   { destURL.stopAccessingSecurityScopedResource() }
        }

        let items = try FileSystemManager.shared.scan(directory: sourceURL, options: ScanOptions(recursive: true))

        for item in items where !item.isDirectory {
            // Compute relative path to preserve directory structure
            let relative = item.url.path.replacingOccurrences(of: sourceURL.path, with: "")
            let destItemURL = destURL.appendingPathComponent(relative)

            // Create parent directories if needed
            let parentDir = destItemURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            // Skip if destination is already up to date
            if fm.fileExists(atPath: destItemURL.path) {
                let srcAttrs  = try fm.attributesOfItem(atPath: item.url.path)
                let destAttrs = try fm.attributesOfItem(atPath: destItemURL.path)

                let srcModified  = srcAttrs[.modificationDate] as? Date ?? .distantPast
                let destModified = destAttrs[.modificationDate] as? Date ?? .distantPast

                if srcModified <= destModified { continue }

                // Remove stale destination file
                try fm.removeItem(at: destItemURL)
            }

            do {
                try fm.copyItem(at: item.url, to: destItemURL)
                filesCopied += 1
                bytesTransferred += item.sizeBytes
            } catch {
                errors.append(error)
                print("[BackupScheduler] ⚠️ Failed to copy \(item.name): \(error)")
            }
        }

        let result = BackupResult(
            jobID: job.id,
            startedAt: startedAt,
            completedAt: Date(),
            filesCopied: filesCopied,
            bytesTransferred: bytesTransferred,
            errors: errors
        )

        print("[BackupScheduler] ✅ Job \"\(job.name)\" complete — \(filesCopied) files, \(ByteCountFormatter().string(fromByteCount: bytesTransferred)) transferred.")
        return result
    }

    // MARK: - Scheduling

    private func scheduleNextRun(kind: BackupJob.Kind) async {
        let identifier = kind == .iCloud ? BackupScheduler.iCloudTaskID : BackupScheduler.externalTaskID
        let interval   = scheduledJobs.filter { $0.kind == kind }.map { $0.intervalSeconds }.min() ?? 3600

        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        request.requiresNetworkConnectivity = (kind == .iCloud)
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BackupScheduler] 🕐 Next \(kind.rawValue) run scheduled in \(Int(interval))s")
        } catch {
            print("[BackupScheduler] ❌ Failed to schedule background task: \(error)")
        }
    }

    // MARK: - Persistence

    private func saveJobs() {
        do {
            let data = try JSONEncoder().encode(scheduledJobs)
            UserDefaults.standard.set(data, forKey: jobsStorageKey)
        } catch {
            print("[BackupScheduler] ❌ Could not save jobs: \(error)")
        }
    }

    private func loadJobs() {
        guard let data = UserDefaults.standard.data(forKey: jobsStorageKey) else { return }
        do {
            scheduledJobs = try JSONDecoder().decode([BackupJob].self, from: data)
            print("[BackupScheduler] ♻️ Loaded \(scheduledJobs.count) job(s)")
        } catch {
            print("[BackupScheduler] ❌ Could not load jobs: \(error)")
        }
    }
}

// MARK: - Backup Errors

enum BackupError: LocalizedError {
    case staleBookmark
    case sourceUnreachable
    case destinationUnreachable

    var errorDescription: String? {
        switch self {
        case .staleBookmark:            return "A stored location reference is stale. Re-authorize the folder."
        case .sourceUnreachable:        return "The backup source folder could not be accessed."
        case .destinationUnreachable:   return "The backup destination is not reachable."
        }
    }
}
