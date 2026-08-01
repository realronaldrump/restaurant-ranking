import SwiftUI

@MainActor
struct MergeLocationsView: View {
    @Environment(AppStore.self) private var store
    @State private var keeperID: UUID?
    @State private var duplicateID: UUID?
    @State private var confirming = false
    @State private var suggestionToConfirm: DuplicateLocationSuggestion?
    @State private var isConfirmingSuggestion = false
    @State private var isChoosingManually = false

    var body: some View {
        let suggestions = store.duplicateLocationSuggestions()
        Form {
            if suggestions.isEmpty {
                Section {
                    Label("Nothing needs a decision", systemImage: "checkmark.seal")
                        .font(.headline)
                        .listRowBackground(BBTheme.surface)
                    Text("Restaurants with a matching Maps listing, address, or coordinate are merged for you. Only the unclear ones show up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowBackground(BBTheme.surface)
                } header: {
                    Eyebrow("Suggestions")
                }
            } else {
                Section {
                    ForEach(suggestions) { suggestion in
                        suggestionRow(suggestion)
                    }
                } header: {
                    Eyebrow(suggestions.count == 1 ? "1 possible duplicate" : "\(suggestions.count) possible duplicates")
                } footer: {
                    Text("These share a name but not an address, so they may be two branches. Merge only the ones you know are the same place.")
                }
            }

            Section {
                DisclosureGroup(isExpanded: $isChoosingManually) {
                    Picker("Keep", selection: $keeperID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(store.locations) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Picker("Merge in", selection: $duplicateID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(store.locations.filter { $0.id != keeperID }) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Button("Merge records", role: .destructive) { confirming = true }
                        .disabled(keeperID == nil || duplicateID == nil || keeperID == duplicateID)
                } label: {
                    Label("Merge two records myself", systemImage: "arrow.triangle.merge")
                        .font(.headline)
                }
                .listRowBackground(BBTheme.surface)
            } footer: {
                Text("Every outing, dish, comparison, and Want to Try entry moves to the record you keep.")
            }
        }
        .editorialForm()
        .navigationTitle("Merge Duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .editorialPrompt(isPresented: $isConfirmingSuggestion) {
            let suggestion = suggestionToConfirm
            return EditorialPrompt.destructive(
                "Merge these restaurants?",
                message: suggestion.map {
                    "\($0.duplicate.name) and everything logged there moves into \($0.keeper.name), then the duplicate is removed. This cannot be undone."
                } ?? "",
                actionTitle: "Merge",
                cancelTitle: "Cancel"
            ) {
                if let suggestion {
                    store.merge(suggestion.duplicate, into: suggestion.keeper)
                    Haptics.success()
                }
                suggestionToConfirm = nil
            }
        }
        .editorialPrompt(isPresented: $confirming) {
            EditorialPrompt.destructive(
                "Merge these restaurants?",
                message: "The duplicate is removed once its history has moved. This cannot be undone.",
                actionTitle: "Merge",
                cancelTitle: "Cancel"
            ) {
                merge()
            }
        }
    }

    private func suggestionRow(_ suggestion: DuplicateLocationSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(suggestion.reason.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            recordSummary(suggestion.keeper, role: "Keep")
            recordSummary(suggestion.duplicate, role: "Merge in")
            Button("Merge these") {
                suggestionToConfirm = suggestion
                isConfirmingSuggestion = true
            }
            .font(.callout.weight(.bold))
            .frame(minHeight: 44)
        }
        .padding(.vertical, 6)
        .listRowBackground(BBTheme.surface)
    }

    private func recordSummary(_ location: RestaurantLocation, role: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(role.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(location.name).font(.headline)
                Text(detail(for: location))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(role): \(location.name), \(detail(for: location))")
    }

    private func detail(for location: RestaurantLocation) -> String {
        let visits = location.visitArray.count
        let outings = "\(visits) \(visits == 1 ? "outing" : "outings")"
        let address = location.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !address.isEmpty else { return "\(outings) · No address saved" }
        return "\(outings) · \(address)"
    }

    private func merge() {
        guard let keeper = store.locations.first(where: { $0.id == keeperID }),
              let duplicate = store.locations.first(where: { $0.id == duplicateID }) else { return }
        store.merge(duplicate, into: keeper)
        keeperID = nil
        duplicateID = nil
        Haptics.success()
    }
}
