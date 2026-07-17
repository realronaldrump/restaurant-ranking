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

    static func cached(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    static func store(_ image: UIImage, key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// Synchronously decodes small thumbnail data, memoized across renders.
    static func thumbnail(key: String, data: Data?) -> UIImage? {
        if let hit = cached(key) { return hit }
        guard let data, let image = UIImage(data: data) else { return nil }
        store(image, key: key)
        return image
    }

    /// Downsamples potentially large image data off the main thread.
    static func display(key: String, data: Data?, maxDimension: CGFloat) async -> UIImage? {
        if let hit = cached(key) { return hit }
        guard let data else { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            downsample(data: data, maxDimension: maxDimension)
        }.value
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
struct PhotoImage: View {
    let photo: PhotoEntity
    var displayPixels: CGFloat = 0
    @State private var displayImage: UIImage?

    var body: some View {
        Group {
            if let image = displayImage ?? thumbnail {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(BBTheme.ink.opacity(0.06))
                    .overlay { Image(systemName: "photo").font(.title3).foregroundStyle(.secondary) }
            }
        }
        .task(id: photo.id) {
            guard displayPixels > 0 else { return }
            let key = "display-\(photo.id.uuidString)-\(Int(displayPixels))"
            if let hit = PhotoImageCache.cached(key) { displayImage = hit; return }
            let data = photo.fullData ?? photo.thumbnailData
            displayImage = await PhotoImageCache.display(key: key, data: data, maxDimension: displayPixels)
        }
    }

    private var thumbnail: UIImage? {
        PhotoImageCache.thumbnail(key: "thumb-\(photo.id.uuidString)", data: photo.thumbnailData ?? photo.fullData)
    }
}
