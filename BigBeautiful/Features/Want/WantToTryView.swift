import SwiftUI

@MainActor
struct WantToTryView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var query = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Eyebrow("Saved by the circle")
                    Text("The list before the list.").font(BBTheme.display(37))
                    Text("Places someone at the table thought deserved a future evening.").foregroundStyle(.secondary)
                }.padding(.top, 8)
                if entries.isEmpty {
                    EmptyLedgerView(title: "An admirably blank slate", message: "Save a place from search or any establishment page.", symbol: "bookmark")
                    Button("Add a Place") { router.sheet = .addWant }.buttonStyle(PrimaryButtonStyle())
                } else {
                    ForEach(entries) { entry in
                        if let location = entry.location {
                            Button { router.wantPath.append(.location(location.id)) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: location.category.symbol).font(.title3).foregroundStyle(BBTheme.oxblood).frame(width: 38)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(location.name).font(BBTheme.display(21))
                                        Text(meta(for: entry)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName: "chevron.right").font(.caption)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).ledgerCard()
                        }
                    }
                }
            }.padding(.horizontal, 16).padding(.bottom, 30).readablePageWidth()
        }
        .editorialPage().navigationTitle("Want to Try").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search the list")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { router.sheet = .addWant } label: { Image(systemName: "plus") } } }
    }
    private var entries: [WantEntryEntity] { store.wantEntries.filter { query.isEmpty || $0.location?.name.localizedCaseInsensitiveContains(query) == true } }
    private func meta(for entry: WantEntryEntity) -> String {
        let person = store.people.first { $0.id == entry.addedByID }?.name ?? "Someone"
        let category = entry.location?.category.shortTitle ?? "Place"
        return "\(category) · Added by \(person) \(entry.addedAt.formatted(.relative(presentation: .named)))"
    }
}
