import SwiftUI

@MainActor
struct VisitDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    let visit: VisitEntity
    @State private var editingVisit: VisitEntity?
    @State private var confirmDelete = false
    @State private var selectedPhoto: PhotoViewerSnapshot?
    @State private var pendingDeletion: PendingVisitDeletion?
    @State private var stickerReactionTarget: StickerReactionTarget?

    var body: some View {
        Group {
            if !visit.isAlive {
                ContentUnavailableView("Outing unavailable", systemImage: "fork.knife.circle")
                    .task {
                        await Task.yield()
                        dismiss()
                    }
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
                        Label("Delete entire outing", systemImage: "trash")
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
        .toolbar {
            if store.canEditDinerEntry(visit) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editActionTitle) {
                        if visit.isAlive { editingVisit = visit }
                    }
                }
            }
        }
        .sheet(item: $editingVisit) { AddMoreVisitView(visit: $0, personID: store.currentPerson?.id) }
        .sheet(item: $stickerReactionTarget) { target in
            StickerReactionPickerSheet(visit: visit, target: target)
        }
        .fullScreenCover(item: $selectedPhoto) { PhotoViewer(photo: $0) }
        .editorialPrompt(isPresented: $confirmDelete) {
            deletePrompt
        }
    }

    private var deletePrompt: EditorialPrompt {
        guard let restaurant = visit.location, restaurant.visitArray.count == 1 else {
            return EditorialPrompt.destructive(
                "Delete this entire outing?",
                message: "Every diner entry, dish, and photo saved for this outing will be removed. The restaurant stays in your log.",
                actionTitle: "Delete outing",
                cancelTitle: "Cancel"
            ) {
                deleteVisit(removingRestaurantIfEmpty: false)
            }
        }
        return EditorialPrompt(
            "Delete the last outing?",
            message: "Every diner entry, dish, and photo saved for this outing will be removed. You can keep \(restaurant.name) in your log, or remove it too. Removing the restaurant also deletes its Want to Try entry and every comparison involving it for everyone in your circle.",
            tone: .destructive,
            actions: [
                .destructive("Delete outing only", symbol: "calendar.badge.minus") {
                    deleteVisit(removingRestaurantIfEmpty: false)
                },
                .destructive("Delete outing and restaurant", symbol: "trash") {
                    deleteVisit(removingRestaurantIfEmpty: true)
                },
                .cancel("Cancel")
            ]
        )
    }

    private var editActionTitle: String {
        if store.canEditOuting(visit) { return "Edit outing" }
        if store.needsEntryResponse(for: visit) { return "Add your diner entry" }
        return "Edit your diner entry"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(visit.dateKnowledge == .known ? visit.formattedDateTime() : "Outing date unknown")
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
                Text("Unknown restaurant").font(BBTheme.display(38))
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
            EditorialSectionHeader("Who ate what")
            Text("Everyone at the table keeps their own reaction and dishes. Stickers are just for fun and never change a score.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        let socialReactions = store.stickerReactions(to: person.id, in: visit)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isCurrentPerson ? "Your diner entry" : person.name).font(.headline)
                if person.id == visit.createdByID {
                    Text("Outing creator").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                Spacer()
                if let rating {
                    Label(rating.reaction.title, systemImage: rating.reaction.symbol)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(BBTheme.oxblood)
                }
            }
            if let rating {
                if rating.hazyMemory {
                    Label("Hazy memory · counts less", systemImage: "cloud.fog")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if rating.value != nil || rating.service != nil || rating.atmosphere != nil {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], alignment: .leading, spacing: 10) {
                        if let value = rating.value { subrating("Value", value) }
                        if let service = rating.service { subrating("Service", service) }
                        if let atmosphere = rating.atmosphere { subrating("Atmosphere", atmosphere) }
                    }
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
                            .accessibilityLabel(entry.reaction.title)
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
            if !socialReactions.isEmpty || store.canReactWithSticker(to: person.id, in: visit) {
                Divider()
                stickerReactionSection(for: person, reactions: socialReactions)
            }
            if isCurrentPerson && store.needsEntryResponse(for: visit, personID: person.id) {
                Button { editingVisit = visit } label: {
                    Label("Complete your diner entry", systemImage: "plus.circle.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .editorialCard(padding: 14)
    }

    private func stickerReactionSection(
        for person: PersonEntity,
        reactions: [DinerEntryReactionEntity]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Eyebrow("Sticker reactions")
                Spacer()
                if store.canReactWithSticker(to: person.id, in: visit) {
                    let hasMine = store.myStickerReaction(to: person.id, in: visit) != nil
                    Button {
                        stickerReactionTarget = .init(personID: person.id, personName: person.name)
                    } label: {
                        Label(hasMine ? "Change sticker" : "Add sticker", systemImage: "pawprint.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BBTheme.oxblood)
                }
            }

            if reactions.isEmpty {
                Text("No stickers yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(StickerMascot.allCases) { mascot in
                    stickerFamilyRow(mascot, reactions: reactions)
                }
            }
        }
    }

    @ViewBuilder
    private func stickerFamilyRow(
        _ mascot: StickerMascot,
        reactions: [DinerEntryReactionEntity]
    ) -> some View {
        let familyReactions = reactions.filter { $0.mascot == mascot }
        if !familyReactions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: mascot == .coon ? "pawprint.fill" : "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(mascot == .coon ? BBTheme.oxblood : BBTheme.sage)
                    Text(mascot.title)
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(familyReactions) { reaction in
                            VStack(spacing: 3) {
                                StickerReactionArtwork(reaction: reaction.kind, mascot: mascot, size: 68)
                                Text(reaction.kind.title)
                                    .font(.caption2.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                Text(reactionAuthorName(reaction))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 104)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    private func reactionAuthorName(_ reaction: DinerEntryReactionEntity) -> String {
        if reaction.authorPersonID == store.currentPerson?.id { return "You" }
        return store.person(id: reaction.authorPersonID)?.name ?? "Someone"
    }

    private func participationDescription(_ status: VisitParticipationStatus?) -> String {
        switch status {
        case .pending: "No reaction yet"
        case .declined: "Was there · no reaction"
        case .attended: "Was there · no reaction yet"
        case .notThere: "Was not there"
        case nil: "No reaction yet"
        }
    }

    @ViewBuilder private func photosSection(_ photos: [PhotoEntity]) -> some View {
        if !photos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Photos", eyebrow: "\(photos.count) \(photos.count == 1 ? "photo" : "photos")")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(photos, id: \.objectID) { photo in
                            VStack(alignment: .leading, spacing: 4) {
                                Button {
                                    selectedPhoto = PhotoViewerSnapshot(photo: photo)
                                } label: {
                                    PhotoImage(photo: photo)
                                        .frame(width: 170, height: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open outing photo")
                                Text(photoContributorName(photo))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let caption = photo.caption, !caption.isEmpty {
                                    Text(caption).font(.caption.weight(.semibold)).lineLimit(2)
                                }
                            }
                            .contextMenu {
                                if photo.isAlive, store.canEditPhoto(photo) {
                                    Button("Remove my photo", systemImage: "trash", role: .destructive) {
                                        if photo.isAlive { store.deletePhoto(photo) }
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
        guard let contributorID = photo.personID ?? photo.visit?.createdByID else { return "Added by someone else" }
        if contributorID == store.currentPerson?.id { return "Added by you" }
        return "Added by \(store.person(id: contributorID)?.name ?? "someone else")"
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

    private func subrating(_ title: String, _ reaction: Reaction) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(reaction.compactTitle).font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deleteVisit(removingRestaurantIfEmpty: Bool) {
        guard visit.isAlive else {
            dismiss()
            return
        }
        pendingDeletion = PendingVisitDeletion(
            visitID: visit.id,
            restaurantID: visit.location?.id,
            removesRestaurant: removingRestaurantIfEmpty
        )
        confirmDelete = false
        Task { @MainActor in
            await Task.yield()
            dismiss()
        }
    }

    private func finishPendingDeletion() {
        guard let deletion = pendingDeletion else { return }
        pendingDeletion = nil
        Task { @MainActor in
            await Task.yield()
            guard store.deleteVisit(
                id: deletion.visitID,
                removingRestaurantIfEmpty: deletion.removesRestaurant
            ) else { return }
            if deletion.removesRestaurant, let restaurantID = deletion.restaurantID {
                router.removeRoutes(toDeletedRestaurant: restaurantID)
            }
        }
    }
}

private struct PendingVisitDeletion {
    let visitID: UUID
    let restaurantID: UUID?
    let removesRestaurant: Bool
}

private struct StickerReactionTarget: Identifiable {
    let personID: UUID
    let personName: String
    var id: UUID { personID }
}

@MainActor
private struct StickerReactionPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let visit: VisitEntity
    let target: StickerReactionTarget

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        Group {
            if visit.isAlive {
                pickerContent
            } else {
                ContentUnavailableView("Outing unavailable", systemImage: "fork.knife.circle")
                    .task {
                        await Task.yield()
                        dismiss()
                    }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var pickerContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("React to \(target.personName)")
                            .font(BBTheme.display(30))
                        Text("One sticker per person. Stickers are just for fun and never change a score.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(StickerMascot.allCases) { mascot in
                        mascotSection(mascot)
                        if mascot != .mrBubbles {
                            Divider().padding(.vertical, 2)
                        }
                    }

                    if selectedReaction != nil {
                        Button("Remove my sticker", role: .destructive) { remove() }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .padding(BBTheme.Spacing.page)
                .readablePageWidth()
            }
            .editorialPage()
            .navigationTitle("Sticker Reaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func mascotSection(_ mascot: StickerMascot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: mascot == .coon ? "pawprint.fill" : "sparkles")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(mascot == .coon ? BBTheme.oxblood : BBTheme.sage)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mascot.title)
                        .font(.headline)
                    Text(mascot == .coon ? "The original Coon stickers" : "Mr. Bubbles stickers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(CoonReaction.allCases) { reaction in
                    let selectedHere = isSelected(reaction, mascot: mascot)
                    Button { choose(reaction, mascot: mascot) } label: {
                        VStack(spacing: 6) {
                            StickerReactionArtwork(reaction: reaction, mascot: mascot, size: 88)
                            Text(reaction.title)
                                .font(.caption.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, minHeight: 130, alignment: .top)
                        .background(
                            selectedHere ? BBTheme.oxblood.opacity(0.1) : BBTheme.surface,
                            in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                                .stroke(selectedHere ? BBTheme.oxblood : BBTheme.hairline, lineWidth: selectedHere ? 2 : 1)
                        }
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier(accessibilityIdentifier(for: reaction, mascot: mascot))
                    .accessibilityLabel("\(mascot.title): \(reaction.title)")
                    .accessibilityValue(selectedHere ? "Selected" : "Not selected")
                }
            }
        }
    }

    private var selectedReaction: DinerEntryReactionEntity? {
        guard visit.isAlive else { return nil }
        return store.myStickerReaction(to: target.personID, in: visit)
    }

    private func isSelected(_ reaction: CoonReaction, mascot: StickerMascot) -> Bool {
        selectedReaction?.kind == reaction && selectedReaction?.mascot == mascot
    }

    private func accessibilityIdentifier(for reaction: CoonReaction, mascot: StickerMascot) -> String {
        switch mascot {
        case .coon: "coon-reaction-\(reaction.rawValue)"
        case .mrBubbles: "mr-bubbles-reaction-\(reaction.rawValue)"
        }
    }

    private func choose(_ reaction: CoonReaction, mascot: StickerMascot) {
        guard visit.isAlive else { dismiss(); return }
        guard store.setStickerReaction(reaction, mascot: mascot, to: target.personID, in: visit) else { return }
        Haptics.selection()
        dismiss()
    }

    private func remove() {
        guard visit.isAlive else { dismiss(); return }
        guard store.setStickerReaction(nil, mascot: selectedReaction?.mascot ?? .coon, to: target.personID, in: visit) else { return }
        Haptics.selection()
        dismiss()
    }
}
