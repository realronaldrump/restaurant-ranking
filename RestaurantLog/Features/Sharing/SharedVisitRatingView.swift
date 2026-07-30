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
