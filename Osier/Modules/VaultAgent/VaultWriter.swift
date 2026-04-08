//
//  VaultWriter.swift
//  Osier — Module B: VaultAgent
//
//  Direct .md file read/write engine for local Obsidian-style vaults.
//  Uses security-scoped bookmarks (same pattern as ExternalDriveMonitor)
//  so vault access persists across app launches without re-prompting the user.
//

import Foundation

// MARK: - Vault Registration

struct VaultRegistration: Codable, Identifiable {
    let id: UUID
    let name: String
    let bookmarkData: Data
    var lastAccessedAt: Date?
}

// MARK: - Markdown Frontmatter

struct MarkdownFrontmatter {
    var tags: [String] = []
    var created: Date = Date()
    var aliases: [String] = []
    var customFields: [String: String] = [:]

    func render() -> String {
        var lines = ["---"]
        let formatter = ISO8601DateFormatter()
        lines.append("created: \(formatter.string(from: created))")
        if !tags.isEmpty   { lines.append("tags: [\(tags.joined(separator: ", "))]") }
        if !aliases.isEmpty { lines.append("aliases: [\(aliases.joined(separator: ", "))]") }
        for (key, value) in customFields.sorted(by: { $0.key < $1.key }) { lines.append("\(key): \(value)") }
        lines.append("---\n")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Write Mode

enum WriteMode {
    case create
    case overwrite
    case appendToEnd
    case insertUnderHeading(String)
    case createOrAppend
}

// MARK: - VaultWriter

@MainActor
final class VaultWriter: ObservableObject {

    static let shared = VaultWriter()
    private init() { loadVaults() }

    @Published var registeredVaults: [VaultRegistration] = []

    private let fm         = FileManager.default
    private let storageKey = "osier.vault.registrations"

    // MARK: - Registration

    func registerVault(named name: String, rootURL: URL) throws {
        let accessed = rootURL.startAccessingSecurityScopedResource()
        defer { if accessed { rootURL.stopAccessingSecurityScopedResource() } }

        let bookmarkData = try rootURL.bookmarkData(options: .minimalBookmark,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil)
        registeredVaults.removeAll { $0.name.lowercased() == name.lowercased() }
        registeredVaults.append(VaultRegistration(id: UUID(), name: name, bookmarkData: bookmarkData))
        saveVaults()
        print("[VaultWriter] ✅ Registered vault: \(name)")
    }

    func removeVault(id: UUID) {
        registeredVaults.removeAll { $0.id == id }
        saveVaults()
    }

    // MARK: - URL Resolution

    private func resolveVault(named name: String) throws -> URL {
        guard let vault = registeredVaults.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw VaultWriterError.vaultNotRegistered(name)
        }
        var isStale = false
        let url = try URL(resolvingBookmarkData: vault.bookmarkData,
                          options: .withoutUI, relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        if isStale { throw VaultWriterError.staleBookmark(name) }
        guard url.startAccessingSecurityScopedResource() else {
            throw VaultWriterError.accessDenied(url)
        }
        return url
    }

    // MARK: - Core Write

    @discardableResult
    func write(
        filename: String,
        content: String,
        to vaultName: String,
        mode: WriteMode,
        subpath: String? = nil,
        frontmatter: MarkdownFrontmatter? = nil
    ) throws -> URL {
        let vaultURL  = try resolveVault(named: vaultName)
        defer { vaultURL.stopAccessingSecurityScopedResource() }

        let folderURL = subpath.map { vaultURL.appendingPathComponent($0) } ?? vaultURL
        if !fm.fileExists(atPath: folderURL.path) {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }

        let name    = filename.hasSuffix(".md") ? filename : "\(filename).md"
        let fileURL = folderURL.appendingPathComponent(name)

        switch mode {
        case .create:
            guard !fm.fileExists(atPath: fileURL.path) else { throw VaultWriterError.fileAlreadyExists(fileURL) }
            try buildFullContent(content: content, frontmatter: frontmatter)
                .write(to: fileURL, atomically: true, encoding: .utf8)

        case .overwrite:
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

        case .appendToEnd:
            if fm.fileExists(atPath: fileURL.path) {
                let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                try (existing + "\n" + content).write(to: fileURL, atomically: true, encoding: .utf8)
            } else {
                try buildFullContent(content: content, frontmatter: frontmatter)
                    .write(to: fileURL, atomically: true, encoding: .utf8)
            }

        case .insertUnderHeading(let heading):
            guard fm.fileExists(atPath: fileURL.path) else { throw VaultWriterError.fileNotFound(fileURL) }
            let result = try insertUnderHeading(heading, content: content, in: fileURL)
            try result.write(to: fileURL, atomically: true, encoding: .utf8)

        case .createOrAppend:
            return try write(filename: filename, content: content, to: vaultName,
                             mode: fm.fileExists(atPath: fileURL.path) ? .appendToEnd : .create,
                             subpath: subpath, frontmatter: frontmatter)
        }

        print("[VaultWriter] ✅ Written: \(name) in vault \"\(vaultName)\"")
        return fileURL
    }

    // MARK: - Daily Note

    @discardableResult
    func writeDailyNote(content: String, to vaultName: String,
                        subpath: String = "Daily Notes", timestamped: Bool = true) throws -> URL {
        let dateFmt      = DateFormatter(); dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt      = DateFormatter(); timeFmt.dateFormat = "HH:mm"
        let filename     = dateFmt.string(from: Date())
        let finalContent = timestamped ? "## \(timeFmt.string(from: Date()))\n\(content)" : content
        return try write(filename: filename, content: finalContent, to: vaultName,
                         mode: .createOrAppend, subpath: subpath,
                         frontmatter: MarkdownFrontmatter(tags: ["daily"]))
    }

    // MARK: - Read

    func read(filename: String, from vaultName: String, subpath: String? = nil) throws -> String {
        let vaultURL  = try resolveVault(named: vaultName)
        defer { vaultURL.stopAccessingSecurityScopedResource() }
        let folderURL = subpath.map { vaultURL.appendingPathComponent($0) } ?? vaultURL
        let name      = filename.hasSuffix(".md") ? filename : "\(filename).md"
        let fileURL   = folderURL.appendingPathComponent(name)
        guard fm.fileExists(atPath: fileURL.path) else { throw VaultWriterError.fileNotFound(fileURL) }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    // MARK: - List

    func listFiles(in vaultName: String, subpath: String? = nil) throws -> [String] {
        let vaultURL  = try resolveVault(named: vaultName)
        defer { vaultURL.stopAccessingSecurityScopedResource() }
        let folderURL = subpath.map { vaultURL.appendingPathComponent($0) } ?? vaultURL
        return (try fm.contentsOfDirectory(atPath: folderURL.path)).filter { $0.hasSuffix(".md") }
    }

    // MARK: - Helpers

    private func buildFullContent(content: String, frontmatter: MarkdownFrontmatter?) -> String {
        frontmatter.map { $0.render() + content } ?? content
    }

    private func insertUnderHeading(_ heading: String, content: String, in fileURL: URL) throws -> String {
        let existing = try String(contentsOf: fileURL, encoding: .utf8)
        var lines    = existing.components(separatedBy: "\n")
        let target   = heading.hasPrefix("#") ? heading : "## \(heading)"
        guard let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == target.lowercased()
        }) else { throw VaultWriterError.headingNotFound(heading, fileURL) }
        lines.insert(contentsOf: content.components(separatedBy: "\n"), at: index + 1)
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func saveVaults() {
        if let data = try? JSONEncoder().encode(registeredVaults) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    private func loadVaults() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let vaults = try? JSONDecoder().decode([VaultRegistration].self, from: data) {
            registeredVaults = vaults
            print("[VaultWriter] ♻️ Loaded \(vaults.count) vault(s)")
        }
    }
}

// MARK: - Errors

enum VaultWriterError: LocalizedError {
    case vaultNotRegistered(String), staleBookmark(String), accessDenied(URL)
    case fileNotFound(URL), fileAlreadyExists(URL), headingNotFound(String, URL)

    var errorDescription: String? {
        switch self {
        case .vaultNotRegistered(let n): return "No vault registered with name \"\(n)\"."
        case .staleBookmark(let n):      return "Bookmark for vault \"\(n)\" is stale — re-register the folder."
        case .accessDenied(let u):       return "Could not access security scope for: \(u.lastPathComponent)"
        case .fileNotFound(let u):       return "File not found: \(u.lastPathComponent)"
        case .fileAlreadyExists(let u):  return "File already exists: \(u.lastPathComponent)"
        case .headingNotFound(let h, _): return "Heading \"\(h)\" not found in file."
        }
    }
}
