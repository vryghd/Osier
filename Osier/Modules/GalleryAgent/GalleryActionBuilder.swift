//
//  GalleryActionBuilder.swift
//  Osier — Module C: GalleryAgent
//
//  Translates typed GalleryIntent values into ActionPlan objects for Module D.
//  Zero side effects — pure plan construction.
//  All plans route through SafetyProtocolEngine before any execution.
//

import Photos
import Foundation

// MARK: - GalleryIntent

enum GalleryIntent {

    // MARK: Album Operations
    case createAlbum(name: String)
    case addAssetsToAlbum(assetIDs: [String], albumName: String)
    case moveAssetsBetweenAlbums(assetIDs: [String], fromAlbum: String, toAlbum: String)
    case renameAlbum(currentName: String, newName: String)
    case deleteAlbum(name: String)

    // MARK: Trash / Cleanup
    case trashAssets(assetIDs: [String])
    case trashAssetsNearCoordinate(latitude: Double, longitude: Double,
                                   radiusMeters: Double, dateRange: ClosedRange<Date>?)
    case trashDuplicates(assetIDs: [String])       // pre-detected by MetadataEngine
    case trashOversizedVideos(assetIDs: [String])  // pre-detected by MetadataEngine

    // MARK: Smart Sort
    case sortAssetsIntoAlbum(assetIDs: [String], targetAlbum: String, visionLabel: String?)
    case groupByDate(assetIDs: [String], strategy: String)  // "month" | "year"
    case groupByLocation(assetIDs: [String])
}

// MARK: - GalleryActionBuilder

final class GalleryActionBuilder {

    static let shared = GalleryActionBuilder()
    private init() {}

    // MARK: - Entry Point

    func buildPlan(from intent: GalleryIntent, rawCommand: String = "") throws -> ActionPlan {
        switch intent {

        // MARK: - Album Plans

        case .createAlbum(let name):
            return ActionPlan(
                title:   "Create Album: \"\(name)\"",
                summary: "Create a new album named \"\(name)\" in Apple Photos.",
                actions: [
                    ActionItem(
                        type:        .createAlbum,
                        riskLevel:   .low,
                        description: "Create album \"\(name)\"",
                        metadata:    ["albumName": name, "action": "create",
                                      "rawCommand": rawCommand]
                    )
                ]
            )

        case .addAssetsToAlbum(let ids, let albumName):
            return ActionPlan(
                title:   "Add \(ids.count) Photo\(ids.count == 1 ? "" : "s") to \"\(albumName)\"",
                summary: "Add \(ids.count) selected asset(s) to the album \"\(albumName)\". Creates the album if it doesn't exist.",
                actions: [
                    ActionItem(
                        type:        .movePhoto,
                        riskLevel:   .low,
                        description: "Add \(ids.count) asset(s) to \"\(albumName)\"",
                        metadata:    ["assetIDs": ids.joined(separator: ","),
                                      "albumName": albumName, "action": "addToAlbum",
                                      "rawCommand": rawCommand]
                    )
                ]
            )

        case .moveAssetsBetweenAlbums(let ids, let from, let to):
            return ActionPlan(
                title:   "Move \(ids.count) Photo\(ids.count == 1 ? "" : "s"): \"\(from)\" → \"\(to)\"",
                summary: "Remove from \"\(from)\" and add to \"\(to)\". Assets stay in the library.",
                actions: [
                    ActionItem(
                        type:        .movePhoto,
                        riskLevel:   .moderate,
                        description: "Move \(ids.count) asset(s) from \"\(from)\" to \"\(to)\"",
                        metadata:    ["assetIDs": ids.joined(separator: ","),
                                      "fromAlbum": from, "toAlbum": to,
                                      "action": "moveAlbum", "rawCommand": rawCommand]
                    )
                ]
            )

        case .renameAlbum(let current, let new):
            return ActionPlan(
                title:   "Rename Album",
                summary: "Rename \"\(current)\" → \"\(new)\".",
                actions: [
                    ActionItem(
                        type:        .createAlbum,
                        riskLevel:   .low,
                        description: "Rename album \"\(current)\" to \"\(new)\"",
                        metadata:    ["currentName": current, "newName": new,
                                      "action": "renameAlbum", "rawCommand": rawCommand]
                    )
                ]
            )

        case .deleteAlbum(let name):
            return ActionPlan(
                title:   "Delete Album: \"\(name)\"",
                summary: "Delete the album container \"\(name)\". Photos inside are NOT trashed.",
                actions: [
                    ActionItem(
                        type:        .createAlbum,
                        riskLevel:   .high,
                        description: "Delete album \"\(name)\" (album only — photos stay in library)",
                        metadata:    ["albumName": name, "action": "deleteAlbum",
                                      "rawCommand": rawCommand]
                    )
                ]
            )

        // MARK: - Trash Plans

        case .trashAssets(let ids):
            return ActionPlan(
                title:   "Move \(ids.count) Photo\(ids.count == 1 ? "" : "s") to Recently Deleted",
                summary: "Route \(ids.count) asset(s) to iOS Recently Deleted. 30-day recovery window preserved.",
                actions: ids.map { id in
                    ActionItem(
                        type:        .deletePhoto,
                        riskLevel:   .high,
                        description: "Trash photo \(id.prefix(8))…",
                        sourcePath:  id,
                        metadata:    ["assetID": id, "action": "trash", "rawCommand": rawCommand]
                    )
                }
            )

        case .trashAssetsNearCoordinate(let lat, let lng, let radius, let dateRange):
            let summary: String = {
                var s = "Trash photos taken within \(Int(radius))m of (\(String(format: "%.4f", lat)), \(String(format: "%.4f", lng)))"
                if let dr = dateRange {
                    let fmt = DateFormatter(); fmt.dateStyle = .short
                    s += " between \(fmt.string(from: dr.lowerBound)) and \(fmt.string(from: dr.upperBound))"
                }
                s += ". 30-day recovery window preserved."
                return s
            }()

            var meta: [String: String] = [
                "action":       "trashByCoordinate",
                "latitude":     "\(lat)",
                "longitude":    "\(lng)",
                "radiusMeters": "\(radius)",
                "rawCommand":   rawCommand
            ]
            if let dr = dateRange {
                meta["startDate"] = ISO8601DateFormatter().string(from: dr.lowerBound)
                meta["endDate"]   = ISO8601DateFormatter().string(from: dr.upperBound)
            }

            return ActionPlan(
                title:   "Trash Photos Near Location",
                summary: summary,
                actions: [
                    ActionItem(
                        type:        .deletePhoto,
                        riskLevel:   .high,
                        description: "Trash photos within \(Int(radius))m of coordinates",
                        metadata:    meta
                    )
                ]
            )

        case .trashDuplicates(let ids):
            return ActionPlan(
                title:   "Trash \(ids.count) Duplicate Photo\(ids.count == 1 ? "" : "s")",
                summary: "Move \(ids.count) detected duplicate(s) to Recently Deleted. Originals (newest) are kept.",
                actions: ids.map { id in
                    ActionItem(
                        type:        .deletePhoto,
                        riskLevel:   .high,
                        description: "Trash duplicate \(id.prefix(8))…",
                        sourcePath:  id,
                        metadata:    ["assetID": id, "action": "trashDuplicate",
                                      "rawCommand": rawCommand]
                    )
                }
            )

        case .trashOversizedVideos(let ids):
            return ActionPlan(
                title:   "Trash \(ids.count) Oversized Video\(ids.count == 1 ? "" : "s")",
                summary: "Move \(ids.count) long video(s) to Recently Deleted to free storage. 30-day recovery window preserved.",
                actions: ids.map { id in
                    ActionItem(
                        type:        .deletePhoto,
                        riskLevel:   .high,
                        description: "Trash oversized video \(id.prefix(8))…",
                        sourcePath:  id,
                        metadata:    ["assetID": id, "action": "trashVideo",
                                      "rawCommand": rawCommand]
                    )
                }
            )

        // MARK: - Sort Plans

        case .sortAssetsIntoAlbum(let ids, let album, let label):
            let labelNote = label.map { " (Vision label: \($0))" } ?? ""
            return ActionPlan(
                title:   "Sort \(ids.count) Photo\(ids.count == 1 ? "" : "s") into \"\(album)\"",
                summary: "Add \(ids.count) asset(s) to \"\(album)\"\(labelNote). Album is created if it doesn't exist.",
                actions: [
                    ActionItem(
                        type:        .movePhoto,
                        riskLevel:   .low,
                        description: "Add \(ids.count) asset(s) to \"\(album)\"\(labelNote)",
                        metadata:    ["assetIDs":    ids.joined(separator: ","),
                                      "albumName":   album,
                                      "visionLabel": label ?? "",
                                      "action":      "sortIntoAlbum",
                                      "rawCommand":  rawCommand]
                    )
                ]
            )

        case .groupByDate(let ids, let strategy):
            let label = strategy == "year" ? "Year" : "Month"
            return ActionPlan(
                title:   "Group \(ids.count) Photo\(ids.count == 1 ? "" : "s") by \(label)",
                summary: "Create dated albums and distribute \(ids.count) asset(s) into them.",
                actions: [
                    ActionItem(
                        type:        .createAlbum,
                        riskLevel:   .moderate,
                        description: "Group \(ids.count) asset(s) into \(label.lowercased())-based albums",
                        metadata:    ["assetIDs": ids.joined(separator: ","),
                                      "strategy": strategy, "action": "groupByDate",
                                      "rawCommand": rawCommand]
                    )
                ]
            )

        case .groupByLocation(let ids):
            return ActionPlan(
                title:   "Group \(ids.count) Photo\(ids.count == 1 ? "" : "s") by Location",
                summary: "Create rough-location albums and distribute \(ids.count) asset(s) into them.",
                actions: [
                    ActionItem(
                        type:        .createAlbum,
                        riskLevel:   .moderate,
                        description: "Distribute \(ids.count) asset(s) into location-based albums",
                        metadata:    ["assetIDs": ids.joined(separator: ","),
                                      "action": "groupByLocation",
                                      "rawCommand": rawCommand]
                    )
                ]
            )
        }
    }
}
