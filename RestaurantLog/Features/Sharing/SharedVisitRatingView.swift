import SwiftUI

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CategoryArtwork(category: visit.location?.category ?? .fullService, height: 150)
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow("Shared outing · \(visit.dateKnowledge == .known ? visit.date.formatted(date: .abbreviated, time: .omitted) : "Date unknown")")
                        Text(visit.location?.name ?? "Shared outing").font(BBTheme.display(34))
                        Text("\(authorName) included you in this outing. Add only your own reaction and the dishes you personally tried.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        EditorialSectionHeader("Your reaction", eyebrow: "Independent opinion")
                        ReactionPicker(selected: reaction) { reaction = $0 }
                    }
                    yourDishes
                    if !otherDinerDishes.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            EditorialSectionHeader("Others at the table", eyebrow: "Add only if you tried it too")
                            ForEach(otherDinerDishes) { option in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(option.dish.name).font(.headline)
                                        Text("\(option.dinerNames.joined(separator: ", ")) ordered this")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("I Tried This") { add(option.dish) }
                                        .font(.callout.weight(.semibold))
                                        .disabled(hasDraft(named: option.dish.name))
                                }
                                .editorialCard(padding: 14)
                            }
                        }
                    }
                    responseActions
                }.padding(18).readablePageWidth()
            }.editorialPage().navigationTitle("Add Your Entry").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(reaction == nil && !hasValidDishDraft) } }
        }
    }

    private var yourDishes: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeader("What did you eat?", eyebrow: "Optional · your dishes only")
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
                Label("Add My Dish", systemImage: "plus.circle.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var responseActions: some View {
        VStack(spacing: 10) {
            Button("I Was There, No Entry") {
                store.declineRating(for: visit)
                dismiss()
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("I Wasn’t There", role: .destructive) {
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
        guard let personID = store.currentPerson?.id else { return [] }
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

    private func add(_ dish: DishEntity) {
        guard !hasDraft(named: dish.name) else { return }
        dishDrafts.append(.init(name: dish.name, role: dish.role))
    }

    private func save() {
        guard let personID = store.currentPerson?.id else { return }
        if let reaction { _ = store.addRating(to: visit, personID: personID, reaction: reaction) }
        for dish in dishDrafts {
            _ = store.addDish(
                name: dish.name, role: dish.role, reaction: dish.reaction,
                wouldOrderAgain: dish.wouldOrderAgain, to: visit, personID: personID
            )
        }
        Haptics.success(); dismiss()
    }
}

@MainActor
struct CircleSharingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var payload: SharePayload?
    @State private var isPreparing = false
    @State private var isRebuildingShare = false
    @State private var confirmsShareRebuild = false
    @State private var error: String?
    @State private var newPerson = ""

    var body: some View {
        NavigationStack {
            Group {
                if let payload { CloudSharingController(payload: payload) }
                else {
                    ScrollView { VStack(alignment: .leading, spacing: 20) {
                        Eyebrow("Private iCloud circle"); Text("Share with your circle").font(BBTheme.display(36)); Text("Invite up to six people. Everyone can see shared outings, while each diner’s entry and rankings stay personal.").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 12) { ForEach(store.circleMembers) { person in Label(person.name + (person.id == store.currentPerson?.id ? " (this device)" : ""), systemImage: "person.crop.circle.fill") }; if store.circleMembers.count < 6 { HStack { TextField("Circle member", text: $newPerson); Button("Add") { _ = store.addCircleMember(name: newPerson); newPerson = "" }.disabled(newPerson.trimmingCharacters(in: .whitespaces).isEmpty) } } }.editorialCard()
                        Button { prepare() } label: { if isPreparing { ProgressView().frame(maxWidth: .infinity) } else { Label("Create or Manage iCloud Invitation", systemImage: "person.badge.plus").frame(maxWidth: .infinity) } }.buttonStyle(PrimaryButtonStyle()).disabled(isPreparing || store.activeCircle == nil)
                        if let error { Text(error).font(.caption).foregroundStyle(BBTheme.oxblood) }
                        Text("Apple iCloud handles invitations and shared records. The developer does not receive them.").font(.footnote).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow("Sharing recovery")
                            Text("Missing on another phone?").font(.headline)
                            Text("Create a complete copy in a fresh iCloud share, then send a new invitation. The current circle stays untouched as a safety copy.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text("Use this only on the device where the complete history is visible. This circle currently has \(store.locations.count) places and \(store.visits.count) visits.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                confirmsShareRebuild = true
                            } label: {
                                if isRebuildingShare {
                                    ProgressView().frame(maxWidth: .infinity)
                                } else {
                                    Label("Rebuild iCloud Share", systemImage: "arrow.triangle.2.circlepath.icloud")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(isPreparing || store.activeCircle == nil)
                        }
                        .editorialCard()
                    }.padding(20).readablePageWidth() }.editorialPage()
                }
            }
            .navigationTitle("Your Circle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .alert("Rebuild iCloud sharing?", isPresented: $confirmsShareRebuild) {
                Button("Cancel", role: .cancel) {}
                Button("Create New Share") { rebuildShare() }
            } message: {
                Text("Continue only if this device shows the complete history. A full recovery copy will become the active circle and use a brand-new iCloud share. The original circle and all of its data will remain on this device. Everyone else must accept the new invitation.")
            }
        }
    }
    private func prepare() {
        guard let circle = store.activeCircle else { return }
        error = nil
        isPreparing = true
        Task {
            do {
                payload = try await CloudSharingService.shared.payload(for: circle, persistence: store.persistence)
            } catch {
                self.error = error.localizedDescription
            }
            isPreparing = false
        }
    }

    private func rebuildShare() {
        guard let circle = store.activeCircle else { return }
        error = nil
        isPreparing = true
        isRebuildingShare = true
        Task {
            do {
                payload = try await CloudSharingService.shared.recoveryPayload(for: circle, store: store)
            } catch {
                self.error = error.localizedDescription
            }
            isRebuildingShare = false
            isPreparing = false
        }
    }
}

@MainActor
struct DeviceIdentitySelectionView: View {
    @Environment(AppStore.self) private var store
    @State private var newPerson = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(BBTheme.oxblood)
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow("Shared circle")
                        Text("Who are you in this circle?").font(BBTheme.display(36))
                        Text("Choose before adding ratings or visits. This selection applies only to this device and this circle.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 10) {
                        ForEach(store.circleMembers) { person in
                            Button {
                                store.selectCurrentPerson(person.id)
                            } label: {
                                HStack {
                                    Circle().fill(Color(hex: person.colorHex)).frame(width: 28, height: 28)
                                    Text(person.name).font(.headline)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                                .padding(16)
                                .frame(minHeight: 56)
                                .background(BBTheme.ink.opacity(0.045))
                                .overlay(Rectangle().stroke(BBTheme.hairline))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if store.circleMembers.count < 6 {
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow("Not listed?")
                            TextField("Your name", text: $newPerson)
                                .textInputAutocapitalization(.words)
                                .padding(12)
                                .background(BBTheme.ink.opacity(0.045))
                            Button("Add Me to This Circle") {
                                guard let person = store.addCircleMember(name: newPerson) else { return }
                                store.selectCurrentPerson(person.id)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(newPerson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .editorialCard()
                    }
                    Text("You can change this later in Settings. Rankings remain separate for each person.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(22)
                .readablePageWidth()
            }
            .editorialPage()
            .navigationTitle(store.activeCircle?.name ?? "Your Circle")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
