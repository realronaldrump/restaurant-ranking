import SwiftUI

@MainActor
struct VisitDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let visit: VisitEntity
    @State private var editingVisit: VisitEntity?
    @State private var confirmDelete = false
    @State private var selectedPhoto: PhotoEntity?

    var body: some View {
        let ratingValues = visit.ratingArray
        let dishEntries = visit.dishEntryArray
        let photoValues = visit.photoArray
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                ratingsSection(ratingValues)
                dishesSection(dishEntries)
                photosSection(photoValues)
                memory
                companions
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete this visit", systemImage: "trash") }.frame(maxWidth: .infinity).padding(.top, 20)
            }.padding(18).readablePageWidth()
        }
        .editorialPage().navigationTitle("Visit").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editingVisit = visit } } }
        .sheet(item: $editingVisit) { AddMoreVisitView(visit: $0, personID: store.currentPerson?.id) }
        .fullScreenCover(item: $selectedPhoto) { PhotoViewer(photo: $0) }
        .confirmationDialog("Delete this visit?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Visit", role: .destructive) { store.deleteVisit(visit); dismiss() }
        } message: { Text("The restaurant remains in your ledger. This visit and its ratings, dishes, and app-stored photos will be removed.") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(visit.date.formatted(date: .complete, time: .omitted))
            Text(visit.location?.name ?? "Unknown place").font(BBTheme.display(38))
            HStack(spacing: 8) {
                if let type = visit.visitType { RankChip(text: type.rawValue, emphasized: true) }
                if visit.priceBand > 0 { RankChip(text: String(repeating: "$", count: Int(visit.priceBand))) }
                if let occasion = visit.occasion { RankChip(text: occasion.rawValue) }
                if visit.isShared { RankChip(text: "Shared") }
            }
        }
    }

    @ViewBuilder private func ratingsSection(_ ratings: [RatingEntity]) -> some View {
        if ratings.isEmpty {
            VStack(spacing: 4) {
                EmptyLedgerView(title: "An unrated visit", message: "It counts in history and contributes nothing to rankings.", symbol: "questionmark.circle")
                Button("Rate This Visit") { editingVisit = visit }.buttonStyle(PrimaryButtonStyle())
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Reactions", eyebrow: "Independent opinions")
                ForEach(ratings) { rating in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(store.people.first(where: { $0.id == rating.personID })?.name ?? "Diner").font(.headline)
                            Spacer(); Label(rating.reaction.rawValue, systemImage: rating.reaction.symbol).font(.callout.weight(.semibold)).foregroundStyle(BBTheme.oxblood)
                        }
                        if rating.hazyMemory { Label("Hazy memory · lightly weighted", systemImage: "cloud.fog").font(.caption).foregroundStyle(.secondary) }
                        HStack { subrating("Value", rating.value); subrating("Service", rating.service); subrating("Atmosphere", rating.atmosphere) }
                    }.ledgerCard()
                }
                if store.currentPerson.flatMap({ person in ratings.first { $0.personID == person.id } }) == nil {
                    Button { editingVisit = visit } label: {
                        Label("Add Your Rating", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    @ViewBuilder private func dishesSection(_ entries: [DishEntryEntity]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("What was ordered", eyebrow: "Dish memory")
                ForEach(entries) { entry in
                    HStack { VStack(alignment: .leading) { Text(entry.dish?.name ?? "Dish").font(.headline); Text(entry.dish?.role.rawValue ?? "").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: entry.reaction.symbol).foregroundStyle(BBTheme.oxblood); if entry.wouldOrderAgain { Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(BBTheme.sage).accessibilityLabel("Would order again") } }.padding(.vertical, 5)
                }
            }
        }
    }

    @ViewBuilder private func photosSection(_ photos: [PhotoEntity]) -> some View {
        if !photos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Photos", eyebrow: "\(photos.count) \(photos.count == 1 ? "frame" : "frames")")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(photos) { photo in
                            Button { selectedPhoto = photo } label: {
                                PhotoImage(photo: photo).frame(width: 170, height: 150).clipped()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open meal photo")
                            .contextMenu {
                                Button("Remove Photo", systemImage: "trash", role: .destructive) { store.deletePhoto(photo) }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var memory: some View {
        if let memory = visit.memory, !memory.isEmpty {
            VStack(alignment: .leading, spacing: 9) { Eyebrow("Memory"); Text("“\(memory)”").font(BBTheme.display(23, weight: .regular)).lineSpacing(4) }.padding(.vertical, 8)
        }
    }

    @ViewBuilder private var companions: some View {
        let names = visit.companionIDs.compactMap { id in store.people.first(where: { $0.id == id })?.name }
        if !names.isEmpty { VStack(alignment: .leading, spacing: 7) { Eyebrow("At the table"); Text(names.joined(separator: ", ")).font(.headline) } }
    }

    private func subrating(_ title: String, _ reaction: Reaction?) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary); Text(reaction?.compactTitle ?? "Not rated").font(.caption) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
