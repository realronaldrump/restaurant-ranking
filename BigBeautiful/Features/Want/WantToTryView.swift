import SwiftUI

@MainActor
struct WantToTryView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var effectiveQuery = ""

    var body: some View {
        let entries = visibleEntries
        let peopleByID = Dictionary(uniqueKeysWithValues: store.people.map { ($0.id, $0.name) })
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Eyebrow("Saved places")
                    Text("Want to Try").font(BBTheme.display(37))
                    Text("Places you or someone in your circle saved for later.").foregroundStyle(.secondary)
                }.padding(.top, 8)
                if entries.isEmpty {
                    EmptyLedgerView(title: "Nothing saved yet", message: "Save a place from search or a restaurant page.", symbol: "bookmark")
                    Button("Add a Place") { router.sheet = .addWant }.buttonStyle(PrimaryButtonStyle())
                } else {
                    ForEach(entries) { entry in
                        if let location = entry.location {
                            Button { router.wantPath.append(.location(location.id)) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: location.category.symbol).font(.title3).foregroundStyle(BBTheme.oxblood).frame(width: 38)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(location.name).font(BBTheme.display(21))
                                        Text(meta(for: entry, peopleByID: peopleByID)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName: "chevron.right").font(.caption)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.pressable).ledgerCard()
                        }
                    }
                }
            }.padding(.horizontal, 16).padding(.bottom, 30).readablePageWidth()
        }
        .editorialPage().navigationTitle("Want to Try").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search the list")
        .task(id: query) {
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            effectiveQuery = query
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { router.sheet = .addWant } label: { Image(systemName: "plus") } } }
    }
    private var visibleEntries: [WantEntryEntity] {
        store.wantEntries.filter { effectiveQuery.isEmpty || $0.location?.name.localizedCaseInsensitiveContains(effectiveQuery) == true }
    }
    private func meta(for entry: WantEntryEntity, peopleByID: [UUID: String]) -> String {
        let person = peopleByID[entry.addedByID] ?? "Someone"
        let category = entry.location?.category.shortTitle ?? "Place"
        return "\(category) · Added by \(person) \(entry.addedAt.formatted(.relative(presentation: .named)))"
    }
}
