import SwiftUI

@MainActor
struct AddWantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @State private var query = ""
    @State private var mapResults: [PlaceCandidate] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Your ledger") { ForEach(local) { location in row(location.name, subtitle: location.category.shortTitle) { store.toggleWant(location); dismiss() } } }
                if !mapResults.isEmpty { Section("Map results") { ForEach(mapResults) { candidate in row(candidate.name, subtitle: candidate.address ?? candidate.suggestedCategory.shortTitle) { let location = store.createLocation(name: candidate.name, category: candidate.suggestedCategory, address: candidate.address, city: candidate.city, coordinate: (candidate.latitude, candidate.longitude), phone: candidate.phone, url: candidate.url, sourceIdentifier: candidate.id, cuisines: candidate.cuisines); store.toggleWant(location); dismiss() } } } }
            }.scrollContentBackground(.hidden).background(PaperBackground()).searchable(text: $query, prompt: "Find a place to save")
            .navigationTitle("Add to Want to Try").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: query) { guard !query.isEmpty else { mapResults = []; return }; try? await Task.sleep(for: .milliseconds(280)); mapResults = await locationService.search(query) }
        }
    }
    private var local: [RestaurantLocation] { store.locations.filter { !store.isWanted($0) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) } }
    private func row(_ title: String, subtitle: String, action: @escaping () -> Void) -> some View { Button(action: action) { HStack { VStack(alignment: .leading) { Text(title).foregroundStyle(BBTheme.ink); Text(subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "bookmark") } }.frame(minHeight: 44) }
}
