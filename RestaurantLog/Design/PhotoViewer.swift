import SwiftUI

struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let photo: PhotoEntity
    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var dragOffset: CGSize = .zero
    @State private var lastDragOffset: CGSize = .zero

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
                    .accessibilityLabel("Meal photo from \(photo.createdAt.formatted(date: .abbreviated, time: .shortened))")
            } else if loadFailed {
                ContentUnavailableView("Photo unavailable", systemImage: "photo.badge.exclamationmark").foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 46, height: 46).background(.black.opacity(0.6), in: Circle()) }
                .padding(18).accessibilityLabel("Close photo")
        }
        .statusBarHidden()
        .task {
            let key = "viewer-\(photo.id.uuidString)"
            image = await PhotoImageCache.display(key: key, data: photo.fullData ?? photo.thumbnailData, maxDimension: 2_800)
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
