import CoreLocation
import CoreTransferable
import ImageIO
import Photos
import PhotosUI
import SwiftUI
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

enum PhotoMemoryPolicy {
    static let maximumConcurrentProcessing = 3
    static let maximumSourceFileBytes = 32 * 1_024 * 1_024
    static let maximumPreparedPhotoBytes = 8 * 1_024 * 1_024
    static let maximumPreparedOutputBytes = 64 * 1_024 * 1_024
    static let maximumSourcePixels = 64_000_000

    static func clampedConcurrency(_ requested: Int) -> Int {
        min(max(1, requested), maximumConcurrentProcessing)
    }

    static func acceptsSourceFile(byteCount: Int64) -> Bool {
        byteCount >= 0 && byteCount <= Int64(maximumSourceFileBytes)
    }

    static func acceptsAsset(pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard pixelWidth > 0, pixelHeight > 0 else { return false }
        let (pixels, overflowed) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        return !overflowed && pixels <= maximumSourcePixels
    }

    static func canRetainPreparedPhoto(
        currentBytes: Int,
        fullBytes: Int,
        thumbnailBytes: Int
    ) -> Bool {
        guard currentBytes >= 0, fullBytes >= 0, thumbnailBytes >= 0 else { return false }
        let (photoBytes, photoOverflowed) = fullBytes.addingReportingOverflow(thumbnailBytes)
        guard !photoOverflowed, photoBytes <= maximumPreparedPhotoBytes else { return false }
        let (totalBytes, totalOverflowed) = currentBytes.addingReportingOverflow(photoBytes)
        return !totalOverflowed && totalBytes <= maximumPreparedOutputBytes
    }
}

private enum BoundedPhotoFileError: Error {
    case oversized
    case unreadable
}

private struct BoundedPhotoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("restaurant-photo-\(UUID().uuidString)")
            try BoundedPhotoFileIO.copy(received.file, to: destination)
            return BoundedPhotoFile(url: destination)
        }
    }
}

private enum BoundedPhotoFileIO {
    static func copy(_ source: URL, to destination: URL) throws {
        if let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           !PhotoMemoryPolicy.acceptsSourceFile(byteCount: Int64(size)) {
            throw BoundedPhotoFileError.oversized
        }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw BoundedPhotoFileError.unreadable
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            defer {
                try? input.close()
                try? output.close()
            }
            var totalBytes: Int64 = 0
            while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                let (nextTotal, overflowed) = totalBytes.addingReportingOverflow(Int64(chunk.count))
                guard !overflowed, PhotoMemoryPolicy.acceptsSourceFile(byteCount: nextTotal) else {
                    throw BoundedPhotoFileError.oversized
                }
                try output.write(contentsOf: chunk)
                totalBytes = nextTotal
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func mappedData(from url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize,
              PhotoMemoryPolicy.acceptsSourceFile(byteCount: Int64(size)) else {
            throw BoundedPhotoFileError.oversized
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard PhotoMemoryPolicy.acceptsSourceFile(byteCount: Int64(data.count)) else {
            throw BoundedPhotoFileError.oversized
        }
        return data
    }
}

enum MealPhotoDraftPolicy {
    /// Tight enough to avoid presenting an entire neighborhood as a photo
    /// match, while allowing for ordinary phone GPS drift around a building.
    static let restaurantLookupRadius: CLLocationDistance = 175

    /// A picker-provided file usually retains its original EXIF capture time.
    /// Screenshots and exported images often do not, so a current-meal draft
    /// must fall back visibly rather than pretending the fallback came from EXIF.
    static func visitDate(for photo: BackfillPhoto, fallback: Date) -> Date {
        photo.captureDate ?? fallback
    }
}

struct BackfillPhoto: Identifiable, Sendable {
    let id: UUID
    let fullData: Data
    let thumbnailData: Data?
    let date: Date
    let coordinate: CLLocationCoordinate2D?
    /// The timestamp read from the image itself. `date` may instead contain a
    /// caller-provided fallback used for storing an otherwise valid image.
    let captureDate: Date?

    init(
        id: UUID,
        fullData: Data,
        thumbnailData: Data?,
        date: Date,
        coordinate: CLLocationCoordinate2D?,
        captureDate: Date? = nil
    ) {
        self.id = id
        self.fullData = fullData
        self.thumbnailData = thumbnailData
        self.date = date
        self.coordinate = coordinate
        self.captureDate = captureDate
    }
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
    /// Processes picker selections in small parallel batches. This is noticeably
    /// faster than serial imports while keeping peak image-decoding memory bounded.
    static func processSelected(
        _ items: [PhotosPickerItem],
        fallbackDate: Date?,
        maxConcurrent: Int = 3
    ) async -> [BackfillPhoto] {
        let batchSize = PhotoMemoryPolicy.clampedConcurrency(maxConcurrent)
        var orderedResults: [(index: Int, photo: BackfillPhoto)] = []
        var retainedBytes = 0

        for batchStart in stride(from: 0, to: items.count, by: batchSize) {
            let batchEnd = min(items.count, batchStart + batchSize)
            let batch = Array(items[batchStart..<batchEnd])
            let results = await withTaskGroup(of: (Int, BackfillPhoto?).self) { group in
                for (offset, item) in batch.enumerated() {
                    let index = batchStart + offset
                    group.addTask {
                        guard let transferred = try? await item.loadTransferable(type: BoundedPhotoFile.self) else {
                            return (index, nil)
                        }
                        defer { try? FileManager.default.removeItem(at: transferred.url) }
                        return (index, await processOffMain(fileURL: transferred.url, date: fallbackDate))
                    }
                }
                var values: [(Int, BackfillPhoto?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (index, photo) in results.sorted(by: { $0.0 < $1.0 }) {
                guard let photo,
                      PhotoMemoryPolicy.canRetainPreparedPhoto(
                        currentBytes: retainedBytes,
                        fullBytes: photo.fullData.count,
                        thumbnailBytes: photo.thumbnailData?.count ?? 0
                      ) else { continue }
                retainedBytes += photo.fullData.count + (photo.thumbnailData?.count ?? 0)
                orderedResults.append((index: index, photo: photo))
            }
        }

        return orderedResults.sorted { $0.index < $1.index }.map(\.photo)
    }

    /// ImageIO decode and JPEG encoding are CPU-heavy. Keep them off the UI actor
    /// even when a SwiftUI task initiated the import.
    static func processOffMain(_ data: Data, date fallbackDate: Date? = .now) async -> BackfillPhoto? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool { process(data, date: fallbackDate) }
        }.value
    }

    static func processOffMain(fileURL: URL, date fallbackDate: Date? = .now) async -> BackfillPhoto? {
        guard let data = try? BoundedPhotoFileIO.mappedData(from: fileURL) else { return nil }
        return await processOffMain(data, date: fallbackDate)
    }

    /// Pass a nil fallback for historical backfill imports. That prevents a
    /// metadata-free old photo from silently becoming a visit dated "now".
    static func process(_ data: Data, date fallbackDate: Date? = .now) -> BackfillPhoto? {
        guard PhotoMemoryPolicy.acceptsSourceFile(byteCount: Int64(data.count)) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let captureDate = captureDate(metadata)
        guard let date = captureDate ?? fallbackDate else { return nil }
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
        guard PhotoMemoryPolicy.canRetainPreparedPhoto(
            currentBytes: 0,
            fullBytes: full.count,
            thumbnailBytes: thumbnail?.count ?? 0
        ) else { return nil }
        return BackfillPhoto(
            id: UUID(), fullData: full, thumbnailData: thumbnail,
            date: date, coordinate: coordinate, captureDate: captureDate
        )
    }

    static func clusters(_ photos: [BackfillPhoto]) -> [BackfillCluster] {
        let sorted = photos.sorted { $0.date < $1.date }
        var clusters: [BackfillCluster] = []
        for photo in sorted {
            guard var last = clusters.popLast() else {
                clusters.append(.init(id: UUID(), photos: [photo])); continue
            }
            guard let clusterStart = last.photos.first?.date else {
                clusters.append(.init(id: UUID(), photos: [photo]))
                continue
            }
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
            guard PhotoMemoryPolicy.acceptsAsset(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight),
                  let fileURL = await imageFile(for: asset) else { continue }
            defer { try? FileManager.default.removeItem(at: fileURL) }
            if let photo = await ImageSanitizer.processOffMain(fileURL: fileURL, date: asset.creationDate ?? .now) {
                let assetCoordinate = asset.location?.coordinate
                let corrected = BackfillPhoto(
                    id: photo.id, fullData: photo.fullData, thumbnailData: photo.thumbnailData,
                    date: asset.creationDate ?? photo.date,
                    coordinate: assetCoordinate.flatMap { CLLocationCoordinate2DIsValid($0) ? $0 : nil }
                        ?? photo.coordinate,
                    captureDate: asset.creationDate ?? photo.captureDate
                )
                output.append(corrected)
            }
        }
        return output
    }

    private static func imageFile(for asset: PHAsset) async -> URL? {
        await withCheckedContinuation { continuation in
            guard let resource = PHAssetResource.assetResources(for: asset).first(where: {
                UTType($0.uniformTypeIdentifier)?.conforms(to: .image) == true
            }) else {
                continuation.resume(returning: nil)
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("restaurant-library-photo-\(UUID().uuidString)")
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                guard error == nil,
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      PhotoMemoryPolicy.acceptsSourceFile(byteCount: Int64(size)) else {
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }
}
