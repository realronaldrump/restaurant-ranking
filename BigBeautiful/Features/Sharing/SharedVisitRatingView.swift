import SwiftUI

@MainActor
struct SharedVisitRatingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let visit: VisitEntity
    @State private var reaction: Reaction?
    @State private var dishReactions: [UUID: Reaction] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CategoryArtwork(category: visit.location?.category ?? .fullService, height: 150)
                    VStack(alignment: .leading, spacing: 6) { Eyebrow("Shared visit · \(visit.date.formatted(date: .abbreviated, time: .omitted))"); Text(visit.location?.name ?? "Shared visit").font(BBTheme.display(34)); Text("Choose your reaction for this visit.").foregroundStyle(.secondary) }
                    ReactionPicker(selected: reaction) { reaction = $0 }
                    if !visit.dishEntryArray.isEmpty {
                        EditorialSectionHeader("Dish reactions", eyebrow: "Optional · skipped unless chosen")
                        ForEach(uniqueDishes) { dish in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(dish.name).font(.headline)
                                    Spacer()
                                    if dishReactions[dish.id] != nil {
                                        Button("Clear") { dishReactions[dish.id] = nil }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    }
                                }
                                Picker("Reaction for \(dish.name)", selection: Binding(get: { dishReactions[dish.id] }, set: { dishReactions[dish.id] = $0 })) {
                                    ForEach(Reaction.allCases) { value in
                                        Image(systemName: value.symbol).tag(Reaction?.some(value)).accessibilityLabel(value.rawValue)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }.ledgerCard()
                        }
                    }
                }.padding(18).readablePageWidth()
            }.editorialPage().navigationTitle("Rate This Visit").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(reaction == nil) } }
        }
    }
    private var uniqueDishes: [DishEntity] {
        visit.dishEntryArray.compactMap(\.dish).reduce(into: [DishEntity]()) { accumulator, dish in
            if !accumulator.contains(where: { $0.id == dish.id }) { accumulator.append(dish) }
        }
    }
    private func save() {
        guard let reaction, let personID = store.currentPerson?.id else { return }
        _ = store.addRating(to: visit, personID: personID, reaction: reaction)
        for dish in uniqueDishes {
            guard let dishReaction = dishReactions[dish.id] else { continue }
            let wouldOrderAgain = dishReaction == .loved || dishReaction == .liked
            _ = store.addDish(name: dish.name, role: dish.role, reaction: dishReaction, wouldOrderAgain: wouldOrderAgain, to: visit, personID: personID)
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
    @State private var error: String?
    @State private var newPerson = ""

    var body: some View {
        NavigationStack {
            Group {
                if let payload { CloudSharingController(payload: payload) }
                else {
                    ScrollView { VStack(alignment: .leading, spacing: 20) {
                        Eyebrow("Private iCloud circle"); Text("Share with your circle").font(BBTheme.display(36)); Text("Invite up to six people. Everyone can see shared visits, while rankings stay personal.").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 12) { ForEach(store.circleMembers) { person in Label(person.name + (person.id == store.currentPerson?.id ? " (this device)" : ""), systemImage: "person.crop.circle.fill") }; if store.circleMembers.count < 6 { HStack { TextField("Circle member", text: $newPerson); Button("Add") { _ = store.addPerson(name: newPerson); newPerson = "" }.disabled(newPerson.trimmingCharacters(in: .whitespaces).isEmpty) } } }.ledgerCard()
                        Button { prepare() } label: { if isPreparing { ProgressView().frame(maxWidth: .infinity) } else { Label("Create or Manage iCloud Invitation", systemImage: "person.badge.plus").frame(maxWidth: .infinity) } }.buttonStyle(PrimaryButtonStyle()).disabled(isPreparing || store.activeCircle == nil)
                        if let error { Text(error).font(.caption).foregroundStyle(BBTheme.oxblood) }
                        Text("Apple iCloud handles invitations and shared records. The developer does not receive them.").font(.footnote).foregroundStyle(.secondary)
                    }.padding(20).readablePageWidth() }.editorialPage()
                }
            }.navigationTitle("Your Circle").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
    private func prepare() { guard let circle = store.activeCircle else { return }; isPreparing = true; Task { do { payload = try await CloudSharingService.shared.payload(for: circle, persistence: store.persistence) } catch { self.error = error.localizedDescription }; isPreparing = false } }
}
