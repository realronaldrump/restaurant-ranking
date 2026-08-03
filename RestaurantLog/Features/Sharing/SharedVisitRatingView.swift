import PhotosUI
import SwiftUI
import UIKit

private struct SharedDishDraft: Identifiable {
    let id = UUID()
    var name = ""
    var role: DishRole = .entree
    var reaction: Reaction = .liked
    var wouldOrderAgain = false
}

private struct OtherDinerDish: Identifiable {
    let dish: DishEntity
    let dinerNames: [String]
    var id: UUID { dish.id }
}

@MainActor
struct SharedVisitRatingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let visit: VisitEntity
    @State private var reaction: Reaction?
    @State private var dishDrafts: [SharedDishDraft] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var preparedPhotos: [BackfillPhoto] = []
    @State private var isProcessingPhotos = false
    @State private var isSaving = false
    @State private var photoError: String?
    @State private var photoRequestID = UUID()

    var body: some View {
        Group {
            if visit.isAlive, store.canEditDinerEntry(visit) {
                visitContent
            } else {
                ContentUnavailableView(
                    visit.isAlive ? "Outing is read-only" : "Outing unavailable",
                    systemImage: "fork.knife.circle"
                )
                    .task {
                        await Task.yield()
                        dismiss()
                    }
            }
        }
    }

    private var visitContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CategoryArtwork(category: visit.location?.category ?? .fullService, height: 150)
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow("Shared outing · \(visit.dateKnowledge == .known ? visit.formattedDateTime(dateStyle: .short, timeStyle: .short) : "Date unknown")")
                        Text(visit.location?.name ?? "Shared outing").font(BBTheme.display(34))
                        Text("\(authorName) included you in this outing. Your diner entry contains only your own reaction, dishes, and photos.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        EditorialSectionHeader("Your reaction", eyebrow: "Independent opinion")
                        ReactionPicker(selected: reaction) { reaction = $0 }
                    }
                    yourDishes
                    photosSection
                    if !otherDinerDishes.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            EditorialSectionHeader("Others at the table", eyebrow: "Shared dishes")
                            Text("Add one to your diner entry only if you tried it too.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            ForEach(otherDinerDishes) { option in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(option.dish.name).font(.headline)
                                        Text("\(option.dinerNames.joined(separator: ", ")) ordered this")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("I tried this") { add(option.dish) }
                                        .font(.callout.weight(.semibold))
                                        .disabled(hasDraft(named: option.dish.name))
                                }
                                .editorialCard(padding: 14)
                            }
                        }
                    }
                    responseActions
                }.padding(18).readablePageWidth()
            }.editorialPage().navigationTitle("Add Diner Entry").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(!canSave || isProcessingPhotos || isSaving)
                }
            }
        }
        .onChange(of: photoItems) { _, items in
            Task { await preparePhotos(items) }
        }
    }

    private var yourDishes: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeader("What did you eat?", eyebrow: "Optional")
            Text("Keep this diner entry to dishes you personally tried.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach($dishDrafts) { $dish in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Dish name", text: $dish.name).font(.headline)
                        Button("Remove", systemImage: "xmark.circle.fill") {
                            dishDrafts.removeAll { $0.id == dish.id }
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                    }
                    Picker("Role", selection: $dish.role) {
                        ForEach(DishRole.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Your reaction", selection: $dish.reaction) {
                        ForEach(Reaction.allCases) { Text($0.compactTitle).tag($0) }
                    }
                    Toggle("Would order again", isOn: $dish.wouldOrderAgain)
                }
                .editorialCard()
            }
            Button { dishDrafts.append(.init()) } label: {
                Label("Add my dish", systemImage: "plus.circle.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var photosSection: some View {
        let pickerTitle = photoItems.isEmpty ? "Add photos" : "Change photos"
        return VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeader("Photos", eyebrow: "Optional")

            if !preparedPhotos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(preparedPhotos) { photo in
                            SharedEntryPhotoThumbnail(photo: photo)
                        }
                    }
                }
                .accessibilityLabel("Selected outing photos")
            }

            HStack(spacing: 10) {
                PhotosPicker(
                    selection: $photoItems,
                    maxSelectionCount: 12,
                    matching: .images,
                    preferredItemEncoding: .current
                ) {
                    Label(
                        pickerTitle,
                        systemImage: "photo.on.rectangle"
                    )
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("shared-entry-photo-picker")

                if !photoItems.isEmpty {
                    Button("Remove all") {
                        photoItems = []
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }

            if isProcessingPhotos {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing photos…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if !preparedPhotos.isEmpty {
                Text("\(preparedPhotos.count) photo\(preparedPhotos.count == 1 ? "" : "s") ready to add")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let photoError {
                Label(photoError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(BBTheme.oxblood)
            }

            Text("Saved copies are resized and stripped of embedded GPS metadata.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .editorialCard()
    }

    private var responseActions: some View {
        VStack(spacing: 10) {
            Button("I was there, no diner entry") {
                guard visit.isAlive else { dismiss(); return }
                store.declineRating(for: visit)
                dismiss()
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("I wasn’t there", role: .destructive) {
                guard visit.isAlive else { dismiss(); return }
                store.markNotPresent(for: visit)
                dismiss()
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private var authorName: String {
        store.person(id: visit.createdByID)?.name ?? "Someone in your circle"
    }

    private var otherDinerDishes: [OtherDinerDish] {
        guard visit.isAlive, let personID = store.currentPerson?.id else { return [] }
        let entries = visit.dishEntryArray.filter { $0.personID != personID }
        let grouped = Dictionary(grouping: entries) { $0.dish?.id }
        return grouped.values.compactMap { values in
            guard let dish = values.compactMap(\.dish).first else { return nil }
            let names = Set(values.compactMap { store.person(id: $0.personID)?.name }).sorted()
            return OtherDinerDish(dish: dish, dinerNames: names.isEmpty ? ["Another diner"] : names)
        }.sorted { $0.dish.name.localizedCaseInsensitiveCompare($1.dish.name) == .orderedAscending }
    }

    private func hasDraft(named name: String) -> Bool {
        dishDrafts.contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private var hasValidDishDraft: Bool {
        dishDrafts.contains { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var canSave: Bool {
        reaction != nil || hasValidDishDraft || !preparedPhotos.isEmpty
    }

    private func add(_ dish: DishEntity) {
        guard dish.isAlive else { return }
        guard !hasDraft(named: dish.name) else { return }
        dishDrafts.append(.init(name: dish.name, role: dish.role))
    }

    private func preparePhotos(_ items: [PhotosPickerItem]) async {
        guard visit.isAlive else {
            dismiss()
            return
        }
        let fallbackDate = visit.date
        let requestID = UUID()
        photoRequestID = requestID
        photoError = nil
        preparedPhotos = []

        guard !items.isEmpty else {
            isProcessingPhotos = false
            return
        }

        isProcessingPhotos = true
        let photos = await ImageSanitizer.processSelected(items, fallbackDate: fallbackDate)
        guard photoRequestID == requestID, !Task.isCancelled else { return }
        guard visit.isAlive else {
            isProcessingPhotos = false
            preparedPhotos = []
            dismiss()
            return
        }

        preparedPhotos = photos
        isProcessingPhotos = false
        let failedCount = items.count - photos.count
        if failedCount > 0 {
            photoError = "Could not read \(failedCount) selected photo\(failedCount == 1 ? "" : "s"). Try selecting it again."
        }
    }

    private func save() async {
        guard visit.isAlive,
              let personID = store.currentPerson?.id,
              store.canEditDinerEntry(visit, personID: personID) else {
            dismiss()
            return
        }
        isSaving = true
        defer { isSaving = false }

        if let reaction { _ = store.addRating(to: visit, personID: personID, reaction: reaction) }
        for dish in dishDrafts {
            _ = store.addDish(
                name: dish.name, role: dish.role, reaction: dish.reaction,
                wouldOrderAgain: dish.wouldOrderAgain, to: visit, personID: personID
            )
        }
        for photo in preparedPhotos {
            store.addPhoto(
                fullData: photo.fullData,
                thumbnailData: photo.thumbnailData,
                to: visit,
                personID: personID,
                createdAt: photo.date,
                captureDate: photo.captureDate,
                captureTimeZoneOffsetSeconds: photo.captureTimeZoneOffsetSeconds
            )
        }
        Haptics.success(); dismiss()
    }
}

@MainActor
private struct SharedEntryPhotoThumbnail: View {
    let photo: BackfillPhoto
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(BBTheme.ink.opacity(0.06))
                    .overlay { ProgressView() }
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Selected outing photo")
        .task(id: photo.id) {
            image = await PhotoImageCache.display(
                key: "shared-entry-draft-\(photo.id.uuidString)",
                data: photo.thumbnailData ?? photo.fullData,
                maxDimension: CGFloat(BackfillImportPolicy.thumbnailMaxPixelSize)
            )
        }
    }
}
