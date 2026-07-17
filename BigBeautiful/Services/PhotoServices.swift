import CoreLocation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

enum BackfillImportPolicy {
    /// Bounds both compressed data retained by the confirmation UI and the
    /// transient decode work performed during a single import.
    static let maxPhotoCount = 48
    static let storedImageMaxPixelSize = 2_048
    static let thumbnailMaxPixelSize = 480
    static let clusterTimeInterval: TimeInterval = 2 * 60 * 60
    static let clusterDistanceMeters: CLLocationDistance = 500 * 0.3048
}

struct BackfillPhoto: Identifiable, Sendable {
    let id: UUID
    let fullData: Data
    let thumbnailData: Data?
    let date: Date
    let coordinate: CLLocationCoordinate2D?
}

struct BackfillCluster: Identifiable {
    let id: UUID
    var photos: [BackfillPhoto]
    var date: Date { photos.map(\.date).min() ?? .now }
    var coordinate: CLLocationCoordinate2D? {
        let values = photos.compactMap(\.coordinate)
        guard !values.isEmpty else { return nil }
        let vector = values.reduce(into: (x: 0.0, y: 0.0, z: 0.0)) { result, coordinate in
            let latitude = coordinate.latitude * .pi / 180
            let longitude = coordinate.longitude * .pi / 180
            result.x += cos(latitude) * cos(longitude)
            result.y += cos(latitude) * sin(longitude)
            result.z += sin(latitude)
        }
        let horizontal = hypot(vector.x, vector.y)
        guard horizontal > .ulpOfOne || abs(vector.z) > .ulpOfOne else { return values.first }
        return CLLocationCoordinate2D(
            latitude: atan2(vector.z, horizontal) * 180 / .pi,
            longitude: atan2(vector.y, vector.x) * 180 / .pi
        )
    }
}

enum ImageSanitizer {
    /// ImageIO decode and JPEG encoding are CPU-heavy. Keep them off the UI actor
    /// even when a SwiftUI task initiated the import.
    static func processOffMain(_ data: Data, date fallbackDate: Date? = .now) async -> BackfillPhoto? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool { process(data, date: fallbackDate) }
        }.value
    }

    /// Pass a nil fallback for historical backfill imports. That prevents a
    /// metadata-free old photo from silently becoming a visit dated "now".
    static func process(_ data: Data, date fallbackDate: Date? = .now) -> BackfillPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        guard let date = captureDate(metadata) ?? fallbackDate else { return nil }
        let coordinate = gpsCoordinate(metadata)
        // ImageIO downsamples while decoding, so a 48 MP original never becomes a
        // full-resolution UIKit bitmap. Re-encoding without source properties
        // removes EXIF and GPS metadata from both retained copies.
        guard let storedImage = decodedThumbnail(
            from: source,
            maxPixelSize: BackfillImportPolicy.storedImageMaxPixelSize
        ), let full = encoded(storedImage, quality: 0.84) else { return nil }
        let thumbnail = decodedThumbnail(
            from: source,
            maxPixelSize: BackfillImportPolicy.thumbnailMaxPixelSize
        ).flatMap { encoded($0, quality: 0.76) }
        return BackfillPhoto(id: UUID(), fullData: full, thumbnailData: thumbnail, date: date, coordinate: coordinate)
    }

    static func clusters(_ photos: [BackfillPhoto]) -> [BackfillCluster] {
        let sorted = photos.sorted { $0.date < $1.date }
        var clusters: [BackfillCluster] = []
        for photo in sorted {
            guard var last = clusters.popLast() else {
                clusters.append(.init(id: UUID(), photos: [photo])); continue
            }
            let clusterStart = last.photos.first!.date
            let closeInTime = photo.date.timeIntervalSince(clusterStart) <= BackfillImportPolicy.clusterTimeInterval
            let closeInSpace: Bool = {
                guard let coordinate = photo.coordinate else { return true }
                let candidate = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                return last.photos.compactMap(\.coordinate).allSatisfy { existing in
                    candidate.distance(from: CLLocation(latitude: existing.latitude, longitude: existing.longitude))
                        <= BackfillImportPolicy.clusterDistanceMeters
                }
            }()
            if closeInTime && closeInSpace {
                last.photos.append(photo)
                clusters.append(last)
            } else {
                clusters.append(last)
                clusters.append(.init(id: UUID(), photos: [photo]))
            }
        }
        return clusters
    }

    private static func decodedThumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encoded(_ image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func captureDate(_ metadata: [CFString: Any]) -> Date? {
        let exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any]
        guard let string = exif?[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            if let date = formatter.date(from: string + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: string)
    }

    private static func gpsCoordinate(_ metadata: [CFString: Any]) -> CLLocationCoordinate2D? {
        guard let gps = metadata[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
        let coordinate = CLLocationCoordinate2D(
            latitude: latRef?.uppercased() == "S" ? -latitude : latitude,
            longitude: lonRef?.uppercased() == "W" ? -longitude : longitude
        )
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }
}

enum PhotoLibraryScanner {
    enum ScanError: LocalizedError {
        case permissionDenied
        var errorDescription: String? { "Photo access was not granted." }
    }

    static func scan(
        from start: Date,
        through end: Date,
        limit: Int = BackfillImportPolicy.maxPhotoCount
    ) async throws -> [BackfillPhoto] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw ScanError.permissionDenied }
        let calendar = Calendar.autoupdatingCurrent
        let startBoundary = calendar.startOfDay(for: start)
        let endBoundary = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: end)
        ) ?? end.addingTimeInterval(24 * 60 * 60)
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            startBoundary as NSDate,
            endBoundary as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = min(max(1, limit), BackfillImportPolicy.maxPhotoCount)
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var output: [BackfillPhoto] = []
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            if let data = await imageData(for: asset),
               let photo = await ImageSanitizer.processOffMain(data, date: asset.creationDate ?? .now) {
                let assetCoordinate = asset.location?.coordinate
                let corrected = BackfillPhoto(
                    id: photo.id, fullData: photo.fullData, thumbnailData: photo.thumbnailData,
                    date: asset.creationDate ?? photo.date,
                    coordinate: assetCoordinate.flatMap { CLLocationCoordinate2DIsValid($0) ? $0 : nil }
                        ?? photo.coordinate
                )
                output.append(corrected)
            }
        }
        return output
    }

    private static func imageData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
