import SwiftUI

@MainActor
struct AddWantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @State private var query = ""
    @State private var mapResults: [PlaceCandidate] = []

    var body: some View {
        let localResults = local
        NavigationStack {
            List {
                if !localResults.isEmpty {
                    Section {
                        ForEach(localResults) { location in
                            row(location.name, subtitle: location.category.shortTitle) {
                                store.toggleWant(location)
                                Haptics.selection()
                                dismiss()
                            }
                        }
                    } header: { Eyebrow("Your log") }
                    .listRowBackground(BBTheme.surface)
                }
                if !mapResults.isEmpty {
                    Section {
                        ForEach(mapResults) { candidate in
                            row(candidate.name, subtitle: candidate.address ?? candidate.suggestedCategory.shortTitle) {
                                let location = store.createLocation(
                                    name: candidate.name, category: candidate.suggestedCategory,
                                    address: candidate.address, city: candidate.city,
                                    coordinate: (candidate.latitude, candidate.longitude),
                                    phone: candidate.phone, url: candidate.url,
                                    sourceIdentifier: candidate.id, cuisines: candidate.cuisines
                                )
                                if !store.isWanted(location) { store.toggleWant(location) }
                                Haptics.selection()
                                dismiss()
                            }
                        }
                    } header: { Eyebrow("Map results") }
                    .listRowBackground(BBTheme.surface)
                } else if !trimmedQuery.isEmpty, localResults.isEmpty {
                    Section {
                        if locationService.isSearching {
                            HStack(spacing: 10) { ProgressView(); Text("Searching Apple Maps…") }
                        } else {
                            ContentUnavailableView.search(text: trimmedQuery)
                        }
                    }
                    .listRowBackground(BBTheme.surface)
                }
            }
            .editorialForm()
            .scrollDismissesKeyboard(.immediately)
            .searchable(text: $query, prompt: "Find a restaurant to save")
            .navigationTitle("Add to Want to Try")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: trimmedQuery) {
                guard !trimmedQuery.isEmpty else { mapResults = []; return }
                do { try await Task.sleep(for: .milliseconds(280)) }
                catch { return }
                guard !Task.isCancelled else { return }
                mapResults = await locationService.search(trimmedQuery)
            }
        }
    }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var local: [RestaurantLocation] {
        let wantedLocationIDs = Set(store.wantEntries.compactMap { $0.location?.id })
        return store.locations.filter {
            !wantedLocationIDs.contains($0.id) && (trimmedQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmedQuery))
        }
    }
    private func row(_ title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(BBTheme.ink)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "bookmark").foregroundStyle(BBTheme.oxblood)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
    }
}
