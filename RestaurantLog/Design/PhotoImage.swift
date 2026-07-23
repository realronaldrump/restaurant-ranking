import ImageIO
import SwiftUI

@MainActor
enum PhotoImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 128 * 1_024 * 1_024
        return cache
    }()
    private static var inFlight: [String: Task<UIImage?, Never>] = [:]

    static func cached(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    static func store(_ image: UIImage, key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// Downsamples compressed image data off the main thread.
    static func display(key: String, data: Data?, maxDimension: CGFloat) async -> UIImage? {
        if let hit = cached(key) { return hit }
        if let task = inFlight[key] { return await task.value }
        guard let data else { return nil }
        let task = Task.detached(priority: .userInitiated) {
            downsample(data: data, maxDimension: maxDimension)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { store(image, key: key) }
        return image
    }

    nonisolated private static func downsample(data: Data, maxDimension: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Renders a stored photo scaled to fill: the cached thumbnail appears instantly,
/// and when `displayPixels` is set a sharper rendition is decoded off the main thread.
@MainActor
struct PhotoImage: View {
    let photo: PhotoEntity
    var displayPixels: CGFloat = 0
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(BBTheme.ink.opacity(0.06))
                    .overlay { Image(systemName: "photo").font(.title3).foregroundStyle(.secondary) }
            }
        }
        .task(id: loadID) { await loadImage() }
    }

    private var loadID: String {
        "\(photo.id.uuidString)-\(Int(displayPixels))"
    }

    private func loadImage() async {
        image = nil
        let thumbnailKey = "thumb-\(photo.id.uuidString)"
        if let hit = PhotoImageCache.cached(thumbnailKey) {
            image = hit
        } else {
            let data = photo.thumbnailData ?? photo.fullData
            if let thumbnail = await PhotoImageCache.display(
                key: thumbnailKey,
                data: data,
                maxDimension: CGFloat(BackfillImportPolicy.thumbnailMaxPixelSize)
            ), !Task.isCancelled {
                image = thumbnail
            }
        }

        guard displayPixels > CGFloat(BackfillImportPolicy.thumbnailMaxPixelSize), !Task.isCancelled else { return }
        let displayKey = "display-\(photo.id.uuidString)-\(Int(displayPixels))"
        if let hit = PhotoImageCache.cached(displayKey) {
            image = hit
            return
        }
        let data = photo.fullData ?? photo.thumbnailData
        if let display = await PhotoImageCache.display(key: displayKey, data: data, maxDimension: displayPixels),
           !Task.isCancelled {
            image = display
        }
    }
}
