import SwiftUI

struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let photo: PhotoEntity
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let data = photo.fullData ?? photo.thumbnailData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable().scaledToFit().scaleEffect(scale)
                    .gesture(MagnifyGesture().onChanged { value in scale = (lastScale * value.magnification).clamped(to: 1...5) }.onEnded { _ in lastScale = scale })
                    .onTapGesture(count: 2) { withAnimation(.snappy) { scale = scale > 1 ? 1 : 2; lastScale = scale } }
                    .accessibilityLabel("Meal photo from \(photo.createdAt.formatted(date: .abbreviated, time: .shortened))")
            } else {
                ContentUnavailableView("Photo unavailable", systemImage: "photo.badge.exclamationmark").foregroundStyle(.white)
            }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 46, height: 46).background(.black.opacity(0.6), in: Circle()) }
                .padding(18).accessibilityLabel("Close photo")
        }
        .statusBarHidden()
    }
}
