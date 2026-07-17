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
}

struct BackfillPhoto: Identifiable {
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
        let latitudeTotal = values.reduce(0.0) { $0 + $1.latitude }
        let longitudeTotal = values.reduce(0.0) { $0 + $1.longitude }
        let count = Double(values.count)
        return CLLocationCoordinate2D(latitude: latitudeTotal / count, longitude: longitudeTotal / count)
    }
}

enum ImageSanitizer {
    static func process(_ data: Data, date fallbackDate: Date = .now) -> BackfillPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let date = captureDate(metadata) ?? fallbackDate
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
            let lastPhoto = last.photos.last!
            let closeInTime = photo.date.timeIntervalSince(lastPhoto.date) <= 2 * 60 * 60
            let closeInSpace: Bool = {
                guard let a = photo.coordinate, let b = lastPhoto.coordinate else { return true }
                return CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) <= 500
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
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: string)
    }

    private static func gpsCoordinate(_ metadata: [CFString: Any]) -> CLLocationCoordinate2D? {
        guard let gps = metadata[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
        return .init(latitude: latRef == "S" ? -latitude : latitude, longitude: lonRef == "W" ? -longitude : longitude)
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
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", start as NSDate, end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = min(max(1, limit), BackfillImportPolicy.maxPhotoCount)
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var output: [BackfillPhoto] = []
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            if let data = await imageData(for: asset), let photo = autoreleasepool(invoking: {
                ImageSanitizer.process(data, date: asset.creationDate ?? .now)
            }) {
                let corrected = BackfillPhoto(
                    id: photo.id, fullData: photo.fullData, thumbnailData: photo.thumbnailData,
                    date: asset.creationDate ?? photo.date,
                    coordinate: asset.location?.coordinate ?? photo.coordinate
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
