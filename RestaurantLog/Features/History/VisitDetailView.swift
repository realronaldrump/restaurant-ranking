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
        let photoValues = visit.photoArray
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                companions
                dinerEntriesSection
                photosSection(photoValues)
                if store.canEditOuting(visit) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete Entire Outing", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(BBTheme.Spacing.page)
            .padding(.bottom, 72)
            .readablePageWidth()
        }
        .editorialPage().navigationTitle("Outing").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editingVisit = visit } } }
        .sheet(item: $editingVisit) { AddMoreVisitView(visit: $0, personID: store.currentPerson?.id) }
        .fullScreenCover(item: $selectedPhoto) { PhotoViewer(photo: $0) }
        .confirmationDialog("Delete this entire outing?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Outing", role: .destructive) { deleteVisit() }
        } message: {
            Text("Every diner’s entry, dishes, and app-stored photos for this outing will be removed. The restaurant remains in the log.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(visit.dateKnowledge == .known ? visit.date.formatted(date: .complete, time: .omitted) : "Date unknown")
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

    private var dinerEntriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeader("Diner entries", eyebrow: "Each person rates only what they tried")
            ForEach(store.attendees(for: visit)) { person in
                dinerEntryCard(person)
            }
        }
    }

    private func dinerEntryCard(_ person: PersonEntity) -> some View {
        let rating = visit.rating(for: person.id)
        let dishes = visit.dishEntryArray
            .filter { $0.personID == person.id }
            .sorted { $0.createdAt < $1.createdAt }
        let memory = store.memory(for: visit, personID: person.id)
        let status = visit.participant(for: person.id)?.status
        let isCurrentPerson = person.id == store.currentPerson?.id

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isCurrentPerson ? "Your entry" : person.name).font(.headline)
                if person.id == visit.createdByID {
                    Text("OUTING CREATOR").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                Spacer()
                if let rating {
                    Label(rating.reaction.rawValue, systemImage: rating.reaction.symbol)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(BBTheme.oxblood)
                }
            }
            if let rating {
                if rating.hazyMemory {
                    Label("Hazy memory · lightly weighted", systemImage: "cloud.fog")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], alignment: .leading, spacing: 10) {
                    subrating("Value", rating.value)
                    subrating("Service", rating.service)
                    subrating("Atmosphere", rating.atmosphere)
                }
            } else {
                Text(participationDescription(status))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !dishes.isEmpty {
                Divider()
                ForEach(dishes, id: \.objectID) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.dish?.role.symbol ?? "fork.knife")
                            .foregroundStyle(BBTheme.oxblood)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.dish?.name ?? "Dish").font(.headline)
                            Text(entry.dish?.role.rawValue ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: entry.reaction.symbol)
                            .foregroundStyle(BBTheme.oxblood)
                            .accessibilityLabel(entry.reaction.rawValue)
                        if entry.wouldOrderAgain {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .foregroundStyle(BBTheme.sage)
                                .accessibilityLabel("Would order again")
                        }
                    }
                }
            }
            if let memory, !memory.isEmpty {
                Divider()
                Label(memory, systemImage: "quote.opening")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if isCurrentPerson && rating == nil {
                Button { editingVisit = visit } label: {
                    Label("Complete Your Entry", systemImage: "plus.circle.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .editorialCard(padding: 14)
    }

    private func participationDescription(_ status: VisitParticipationStatus?) -> String {
        switch status {
        case .pending: "Waiting for their response"
        case .declined: "Attended · chose not to rate"
        case .attended: "Attended · no overall rating"
        case .notThere: "Marked as not there"
        case nil: "No overall rating"
        }
    }

    @ViewBuilder private func photosSection(_ photos: [PhotoEntity]) -> some View {
        if !photos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Photos", eyebrow: "\(photos.count) \(photos.count == 1 ? "frame" : "frames")")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(photos, id: \.objectID) { photo in
                            VStack(alignment: .leading, spacing: 4) {
                                Button { selectedPhoto = photo } label: {
                                    PhotoImage(photo: photo)
                                        .frame(width: 170, height: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open meal photo")
                                Text(photoContributorName(photo))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let caption = photo.caption, !caption.isEmpty {
                                    Text(caption).font(.caption.weight(.semibold)).lineLimit(2)
                                }
                            }
                            .contextMenu {
                                if store.canEditPhoto(photo) {
                                    Button("Remove My Photo", systemImage: "trash", role: .destructive) {
                                        store.deletePhoto(photo)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func photoContributorName(_ photo: PhotoEntity) -> String {
        guard let contributorID = photo.personID ?? photo.visit?.createdByID else { return "Added by a diner" }
        if contributorID == store.currentPerson?.id { return "Added by you" }
        return "Added by \(store.person(id: contributorID)?.name ?? "a diner")"
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
