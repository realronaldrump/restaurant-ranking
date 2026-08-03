import SwiftUI

@MainActor
struct PhotoViewerSnapshot: Identifiable {
    let id: UUID
    let createdAt: Date
    let captureDate: Date?
    let captureTimeZoneOffsetSeconds: Int?
    let caption: String?
    let imageData: Data?

    init?(photo: PhotoEntity) {
        guard photo.isAlive else { return nil }
        id = photo.id
        createdAt = photo.createdAt
        captureDate = photo.captureDate
        captureTimeZoneOffsetSeconds = photo.captureTimeZoneOffsetSeconds?.intValue
        caption = photo.caption
        imageData = photo.fullData ?? photo.thumbnailData
    }

    fileprivate static var unavailable: Self {
        .init(id: UUID(), createdAt: .now, captureDate: nil, captureTimeZoneOffsetSeconds: nil, caption: nil, imageData: nil)
    }

    private init(
        id: UUID,
        createdAt: Date,
        captureDate: Date?,
        captureTimeZoneOffsetSeconds: Int?,
        caption: String?,
        imageData: Data?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.captureDate = captureDate
        self.captureTimeZoneOffsetSeconds = captureTimeZoneOffsetSeconds
        self.caption = caption
        self.imageData = imageData
    }

    var formattedDateTime: String {
        DiningDateContext.format(
            captureDate ?? createdAt,
            dateStyle: .short,
            timeStyle: .short,
            offsetSeconds: captureDate == nil ? nil : captureTimeZoneOffsetSeconds
        )
    }
}

struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let photo: PhotoViewerSnapshot
    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var dragOffset: CGSize = .zero
    @State private var lastDragOffset: CGSize = .zero

    init(photo: PhotoViewerSnapshot) {
        self.photo = photo
    }

    init(photo: PhotoEntity) {
        self.photo = PhotoViewerSnapshot(photo: photo) ?? .unavailable
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea().opacity(backgroundOpacity)
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .scaleEffect(scale)
                    .offset(dragOffset)
                    .gesture(magnify)
                    .simultaneousGesture(panOrDismiss)
                    .onTapGesture(count: 2) { toggleZoom() }
                    .accessibilityLabel("Outing photo from \(photo.formattedDateTime)")
            } else if loadFailed {
                ContentUnavailableView("Photo unavailable", systemImage: "photo.badge.exclamationmark").foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
            if let caption = photo.caption, !caption.isEmpty {
                Text(caption)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 24)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 46, height: 46).background(.black.opacity(0.6), in: Circle()) }
                .padding(18).accessibilityLabel("Close photo")
        }
        .statusBarHidden()
        .task {
            let key = "viewer-\(photo.id.uuidString)"
            image = await PhotoImageCache.display(key: key, data: photo.imageData, maxDimension: 2_800)
            loadFailed = image == nil
        }
    }

    private var backgroundOpacity: Double {
        scale > 1.01 ? 1 : max(0.4, 1 - Double(abs(dragOffset.height)) / 500)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in scale = (lastScale * value.magnification).clamped(to: 1...5) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 {
                    dragOffset = .zero
                    lastDragOffset = .zero
                }
            }
    }

    private var panOrDismiss: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1.01 {
                    dragOffset = CGSize(
                        width: lastDragOffset.width + value.translation.width,
                        height: lastDragOffset.height + value.translation.height
                    )
                } else {
                    dragOffset = value.translation
                }
            }
            .onEnded { value in
                if scale > 1.01 {
                    lastDragOffset = dragOffset
                } else if abs(value.translation.height) > 130 {
                    dismiss()
                } else if reduceMotion {
                    dragOffset = .zero
                } else {
                    withAnimation(.snappy) { dragOffset = .zero }
                }
            }
    }

    private func toggleZoom() {
        let changes = {
            scale = scale > 1 ? 1 : 2
            lastScale = scale
            if scale == 1 {
                dragOffset = .zero
                lastDragOffset = .zero
            }
        }
        if reduceMotion { changes() }
        else { withAnimation(.snappy) { changes() } }
    }
}
