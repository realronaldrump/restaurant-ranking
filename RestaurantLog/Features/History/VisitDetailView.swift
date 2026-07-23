import SwiftUI

@MainActor
struct VisitDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let visit: VisitEntity
    @State private var editingVisit: VisitEntity?
    @State private var confirmDelete = false
    @State private var selectedPhoto: PhotoEntity?
    @State private var pendingDeletionID: UUID?

    var body: some View {
        Group {
            if visit.managedObjectContext == nil || visit.isDeleted {
                EmptyView()
            } else {
                visitContent
            }
        }
        .onDisappear { finishPendingDeletion() }
    }

    private var visitContent: some View {
        let ratingValues = store.ratings(for: visit)
        let dishEntries = visit.dishEntryArray
        let photoValues = visit.photoArray
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ratingsSection(ratingValues)
                dishesSection(dishEntries)
                photosSection(photoValues)
                memory
                companions
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete this visit", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(BBTheme.Spacing.page)
            .padding(.bottom, 72)
            .readablePageWidth()
        }
        .editorialPage().navigationTitle("Visit").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editingVisit = visit } } }
        .sheet(item: $editingVisit) { AddMoreVisitView(visit: $0, personID: store.currentPerson?.id) }
        .fullScreenCover(item: $selectedPhoto) { PhotoViewer(photo: $0) }
        .confirmationDialog("Delete this visit?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Visit", role: .destructive) { deleteVisit() }
        } message: {
            Text("The restaurant remains in your log. This visit and its ratings, dishes, and app-stored photos will be removed.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(visit.date.formatted(date: .complete, time: .omitted))
            if let location = visit.location {
                NavigationLink(value: AppRoute.location(location.id)) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(location.name)
                            .font(BBTheme.display(34))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(BBTheme.oxblood)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the restaurant record")
            } else {
                Text("Unknown place").font(BBTheme.display(38))
            }
            FlowLayout(items: headerChips) { chip in
                RankChip(text: chip.text, emphasized: chip.emphasized)
            }
        }
        .editorialCard(padding: 14)
    }

    private struct HeaderChip: Hashable {
        let text: String
        let emphasized: Bool
    }

    private var headerChips: [HeaderChip] {
        var chips: [HeaderChip] = []
        if let type = visit.visitType { chips.append(.init(text: type.rawValue, emphasized: true)) }
        if visit.priceBand > 0 { chips.append(.init(text: String(repeating: "$", count: Int(visit.priceBand)), emphasized: false)) }
        if let occasion = visit.occasion { chips.append(.init(text: occasion.rawValue, emphasized: false)) }
        if store.isSharedVisit(visit) { chips.append(.init(text: "Shared", emphasized: false)) }
        return chips
    }

    @ViewBuilder private func ratingsSection(_ ratings: [RatingEntity]) -> some View {
        if ratings.isEmpty {
            VStack(spacing: 4) {
                EmptyLogView(title: "An unrated visit", message: "It counts in history and contributes nothing to rankings.", symbol: "questionmark.circle")
                Button("Rate This Visit") { editingVisit = visit }.buttonStyle(PrimaryButtonStyle())
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Reactions", eyebrow: "Independent opinions")
                ForEach(ratings, id: \.objectID) { rating in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(store.person(id: rating.personID)?.name ?? "Diner").font(.headline)
                            Spacer(); Label(rating.reaction.rawValue, systemImage: rating.reaction.symbol).font(.callout.weight(.semibold)).foregroundStyle(BBTheme.oxblood)
                        }
                        if rating.hazyMemory { Label("Hazy memory · lightly weighted", systemImage: "cloud.fog").font(.caption).foregroundStyle(.secondary) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], alignment: .leading, spacing: 10) {
                            subrating("Value", rating.value)
                            subrating("Service", rating.service)
                            subrating("Atmosphere", rating.atmosphere)
                        }
                    }.editorialCard(padding: 14)
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
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.objectID) { index, entry in
                        HStack(spacing: 12) {
                            IconTile(symbol: entry.dish?.role.symbol ?? "fork.knife")
                            VStack(alignment: .leading) {
                                Text(entry.dish?.name ?? "Dish").font(.headline)
                                Text(entry.dish?.role.rawValue ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: entry.reaction.symbol).foregroundStyle(BBTheme.oxblood).accessibilityLabel(entry.reaction.rawValue)
                            if entry.wouldOrderAgain {
                                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(BBTheme.sage).accessibilityLabel("Would order again")
                            }
                        }
                        .frame(minHeight: 62)
                        .padding(.vertical, 6)
                        if index < entries.count - 1 { Divider() }
                    }
                }
                .editorialCard(padding: 12)
            }
        }
    }

    @ViewBuilder private func photosSection(_ photos: [PhotoEntity]) -> some View {
        if !photos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Photos", eyebrow: "\(photos.count) \(photos.count == 1 ? "frame" : "frames")")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(photos, id: \.objectID) { photo in
                            Button { selectedPhoto = photo } label: {
                                PhotoImage(photo: photo)
                                    .frame(width: 170, height: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Memory")
                Image(systemName: "quote.opening").font(.title3).foregroundStyle(BBTheme.oxblood.opacity(0.65))
                Text(memory).font(BBTheme.display(23, weight: .regular)).lineSpacing(4)
            }
            .editorialCard(padding: 14)
        }
    }

    @ViewBuilder private var companions: some View {
        let people = store.attendees(for: visit)
        if !people.isEmpty {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: "person.2.fill")
                VStack(alignment: .leading, spacing: 7) {
                    Eyebrow("At the table")
                    Text(people.map(\.name).joined(separator: ", ")).font(.headline)
                    if let author = store.person(id: visit.createdByID) {
                        Text("Logged by \(author.name)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .editorialCard()
        }
    }

    private func subrating(_ title: String, _ reaction: Reaction?) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary); Text(reaction?.compactTitle ?? "Not rated").font(.caption) }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deleteVisit() {
        pendingDeletionID = visit.id
        confirmDelete = false
        Task { @MainActor in
            await Task.yield()
            dismiss()
        }
    }

    private func finishPendingDeletion() {
        guard let visitID = pendingDeletionID else { return }
        pendingDeletionID = nil
        Task { @MainActor in
            await Task.yield()
            store.deleteVisit(id: visitID)
        }
    }
}
