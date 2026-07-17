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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                ratings
                dishes
                photos
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

    @ViewBuilder private var ratings: some View {
        if visit.ratingArray.isEmpty {
            VStack(spacing: 4) {
                EmptyLedgerView(title: "An unrated visit", message: "It counts in history and contributes nothing to rankings.", symbol: "questionmark.circle")
                Button("Rate This Visit") { editingVisit = visit }.buttonStyle(PrimaryButtonStyle())
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Reactions", eyebrow: "Independent opinions")
                ForEach(visit.ratingArray) { rating in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(store.people.first(where: { $0.id == rating.personID })?.name ?? "Diner").font(.headline)
                            Spacer(); Label(rating.reaction.rawValue, systemImage: rating.reaction.symbol).font(.callout.weight(.semibold)).foregroundStyle(BBTheme.oxblood)
                        }
                        if rating.hazyMemory { Label("Hazy memory · lightly weighted", systemImage: "cloud.fog").font(.caption).foregroundStyle(.secondary) }
                        HStack { subrating("Value", rating.value); subrating("Service", rating.service); subrating("Atmosphere", rating.atmosphere) }
                    }.ledgerCard()
                }
                if store.currentPerson.flatMap({ visit.rating(for: $0.id) }) == nil {
                    Button { editingVisit = visit } label: {
                        Label("Add Your Rating", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 2)).frame(minHeight: 48)
                }
            }
        }
    }

    @ViewBuilder private var dishes: some View {
        if !visit.dishEntryArray.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("What was ordered", eyebrow: "Dish memory")
                ForEach(visit.dishEntryArray) { entry in
                    HStack { VStack(alignment: .leading) { Text(entry.dish?.name ?? "Dish").font(.headline); Text(entry.dish?.role.rawValue ?? "").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: entry.reaction.symbol).foregroundStyle(BBTheme.oxblood); if entry.wouldOrderAgain { Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(BBTheme.sage).accessibilityLabel("Would order again") } }.padding(.vertical, 5)
                }
            }
        }
    }

    @ViewBuilder private var photos: some View {
        if !visit.photoArray.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Photos", eyebrow: "Metadata stripped")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(visit.photoArray) { photo in
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
        VStack(alignment: .leading, spacing: 2) { Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary); Text(reaction?.compactTitle ?? "—").font(.caption) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
