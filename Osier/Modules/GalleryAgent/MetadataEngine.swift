//
//  MetadataEngine.swift
//  Osier — Module C: GalleryAgent
//
//  EXIF and GPS metadata extraction engine for PHAssets.
//  Uses PHAsset.location for fast GPS-radius pre-filtering (no image load).
//  Full EXIF requires PHImageManager image data load — used only after
//  the GPS pre-filter narrows the candidate set.
//

import Photos
import CoreLocation
import ImageIO
import Foundation

// MARK: - Asset Metadata

struct AssetMetadata: Identifiable {
    let id: String
    let asset: PHAsset
    let creationDate: Date?
    let modificationDate: Date?
    let location: CLLocation?
    var latitude: Double?  { location?.coordinate.latitude }
    var longitude: Double? { location?.coordinate.longitude }
    let cameraMake: String?
    let cameraModel: String?
    let lensModel: String?
    let focalLength: Double?
    let aperture: Double?
    let shutterSpeed: Double?
    let iso: Int?
    let flash: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let durationSeconds: Double
    let mediaType: PHAssetMediaType
    let mediaSubtypes: PHAssetMediaSubtype
}

// MARK: - Coordinate Filter

struct CoordinateFilter {
    let center: CLLocationCoordinate2D
    let radiusMeters: Double

    func contains(_ location: CLLocation) -> Bool {
        let c = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return location.distance(from: c) <= radiusMeters
    }
}

// MARK: - Grouping Strategy

enum MetadataGroupingStrategy {
    case byMonth
    case byYear
    case byMediaType
    case byRoughLocation
}

// MARK: - MetadataEngine

final class MetadataEngine {

    static let shared = MetadataEngine()
    private init() {}

    // MARK: - Fast GPS Filter (no image load)

    func filterByCoordinate(assets: [PHAsset], filter: CoordinateFilter) -> [PHAsset] {
        assets.filter {
            guard let loc = $0.location else { return false }
            return filter.contains(loc)
        }
    }

    func filterByCoordinate(assets: [PHAsset],
                             latitude: Double, longitude: Double,
                             radiusMeters: Double) -> [PHAsset] {
        filterByCoordinate(
            assets: assets,
            filter: CoordinateFilter(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                radiusMeters: radiusMeters
            )
        )
    }

    // MARK: - Date Filter

    func filterByDateRange(assets: [PHAsset], from start: Date, to end: Date) -> [PHAsset] {
        assets.filter {
            guard let date = $0.creationDate else { return false }
            return date >= start && date <= end
        }
    }

    func filterByRecentDays(_ days: Int, assets: [PHAsset]) -> [PHAsset] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return filterByDateRange(assets: assets, from: cutoff, to: Date())
    }

    // MARK: - Full EXIF Extraction

    func extractMetadata(from asset: PHAsset) async -> AssetMetadata? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous           = false
            options.isNetworkAccessAllowed  = true
            options.deliveryMode            = .fastFormat
            options.version                 = .current

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                guard let data else { continuation.resume(returning: nil); return }
                continuation.resume(returning: Self.parseEXIF(from: data, asset: asset))
            }
        }
    }

    func batchExtractMetadata(from assets: [PHAsset],
                              progress: ((Int, Int) -> Void)? = nil) async -> [AssetMetadata] {
        var results: [AssetMetadata] = []
        let total = assets.count

        await withTaskGroup(of: AssetMetadata?.self) { group in
            for asset in assets { group.addTask { await self.extractMetadata(from: asset) } }
            var done = 0
            for await result in group {
                if let m = result { results.append(m) }
                done += 1
                progress?(done, total)
            }
        }
        return results
    }

    // MARK: - GPS + EXIF Pipeline (optimized)

    /// GPS filter first (cheap), then EXIF only for matches (expensive).
    func extractMetadataForAssetsNear(latitude: Double, longitude: Double,
                                      radiusMeters: Double,
                                      from assets: [PHAsset]) async -> [AssetMetadata] {
        let matches = filterByCoordinate(assets: assets, latitude: latitude,
                                         longitude: longitude, radiusMeters: radiusMeters)
        print("[MetadataEngine] GPS pre-filter: \(matches.count)/\(assets.count) in radius.")
        return await batchExtractMetadata(from: matches)
    }

    // MARK: - Grouping

    func group(assets: [PHAsset], by strategy: MetadataGroupingStrategy) -> [String: [PHAsset]] {
        switch strategy {
        case .byMonth:
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM"
            return Dictionary(grouping: assets) { $0.creationDate.map { fmt.string(from: $0) } ?? "Unknown" }

        case .byYear:
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy"
            return Dictionary(grouping: assets) { $0.creationDate.map { fmt.string(from: $0) } ?? "Unknown" }

        case .byMediaType:
            return Dictionary(grouping: assets) { asset -> String in
                switch asset.mediaType {
                case .image: return asset.mediaSubtypes.contains(.photoLive) ? "Live Photo" : "Photo"
                case .video:
                    if asset.mediaSubtypes.contains(.videoHighFrameRate) { return "Slo-mo" }
                    if asset.mediaSubtypes.contains(.videoTimelapse)     { return "Time-lapse" }
                    return "Video"
                default: return "Other"
                }
            }

        case .byRoughLocation:
            return Dictionary(grouping: assets) { asset -> String in
                guard let loc = asset.location else { return "No Location" }
                let lat = (loc.coordinate.latitude  * 10).rounded() / 10
                let lng = (loc.coordinate.longitude * 10).rounded() / 10
                return "(\(lat), \(lng))"
            }
        }
    }

    // MARK: - Duplicate Candidates

    func findTimestampDuplicates(in assets: [PHAsset]) -> [[PHAsset]] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: assets) { asset -> String in
            guard let d = asset.creationDate else { return "nodate" }
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
            return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)-\(c.hour ?? 0)-\(c.minute ?? 0)-\(c.second ?? 0)"
        }
        return grouped.values.filter { $0.count > 1 }
    }

    func findDimensionDuplicates(in assets: [PHAsset]) -> [[PHAsset]] {
        Dictionary(grouping: assets) { "\($0.pixelWidth)x\($0.pixelHeight)" }
            .values.filter { $0.count > 1 }
    }

    // MARK: - Oversized Video Detection

    /// Returns video assets larger than the given duration threshold.
    func findOversizedVideos(in assets: [PHAsset], minDurationSeconds: Double = 300) -> [PHAsset] {
        assets.filter { $0.mediaType == .video && $0.duration >= minDurationSeconds }
    }

    // MARK: - EXIF Parsing

    private static func parseEXIF(from data: Data, asset: PHAsset) -> AssetMetadata {
        guard
            let source     = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return buildMinimal(from: asset) }

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let gps  = properties[kCGImagePropertyGPSDictionary  as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]

        // Prefer PHAsset.location; fall back to parsing GPS dictionary
        var location: CLLocation? = asset.location
        if location == nil, let gpsDict = gps { location = parseGPS(from: gpsDict) }

        let aperture: Double? = {
            if let f = exif?[kCGImagePropertyExifFNumber as String] as? Double { return f }
            if let av = exif?[kCGImagePropertyExifApertureValue as String] as? Double {
                return pow(2, av / 2)
            }
            return nil
        }()

        return AssetMetadata(
            id:               asset.localIdentifier,
            asset:            asset,
            creationDate:     asset.creationDate,
            modificationDate: asset.modificationDate,
            location:         location,
            cameraMake:       tiff?[kCGImagePropertyTIFFMake  as String] as? String,
            cameraModel:      tiff?[kCGImagePropertyTIFFModel as String] as? String,
            lensModel:        exif?[kCGImagePropertyExifLensModel as String] as? String,
            focalLength:      exif?[kCGImagePropertyExifFocalLength as String] as? Double,
            aperture:         aperture,
            shutterSpeed:     exif?[kCGImagePropertyExifExposureTime as String] as? Double,
            iso:              (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first,
            flash:            (exif?[kCGImagePropertyExifFlash as String] as? Int).map { $0 != 0 } ?? false,
            pixelWidth:       asset.pixelWidth,
            pixelHeight:      asset.pixelHeight,
            durationSeconds:  asset.duration,
            mediaType:        asset.mediaType,
            mediaSubtypes:    asset.mediaSubtypes
        )
    }

    private static func parseGPS(from dict: [String: Any]) -> CLLocation? {
        guard
            let latRef = dict[kCGImagePropertyGPSLatitudeRef  as String] as? String,
            let lat    = dict[kCGImagePropertyGPSLatitude      as String] as? Double,
            let lngRef = dict[kCGImagePropertyGPSLongitudeRef  as String] as? String,
            let lng    = dict[kCGImagePropertyGPSLongitude     as String] as? Double
        else { return nil }

        return CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude:  latRef == "S" ? -lat : lat,
                longitude: lngRef == "W" ? -lng : lng
            ),
            altitude:           dict[kCGImagePropertyGPSAltitude as String] as? Double ?? 0,
            horizontalAccuracy: 65,
            verticalAccuracy:   65,
            timestamp:          Date()
        )
    }

    private static func buildMinimal(from asset: PHAsset) -> AssetMetadata {
        AssetMetadata(id: asset.localIdentifier, asset: asset,
                      creationDate: asset.creationDate, modificationDate: asset.modificationDate,
                      location: asset.location, cameraMake: nil, cameraModel: nil, lensModel: nil,
                      focalLength: nil, aperture: nil, shutterSpeed: nil, iso: nil, flash: false,
                      pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                      durationSeconds: asset.duration, mediaType: asset.mediaType,
                      mediaSubtypes: asset.mediaSubtypes)
    }
}
