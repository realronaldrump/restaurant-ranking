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
                header(entries.count)
                if entries.isEmpty {
                    EmptyLogView(
                        title: query.isEmpty ? "Nothing saved yet" : "No saved places match",
                        message: query.isEmpty ? "Build a shortlist for the next time nobody knows where to eat." : "Try a broader search or clear the search field.",
                        symbol: query.isEmpty ? "bookmark" : "magnifyingglass"
                    )
                    if query.isEmpty {
                        Button("Add a Place") { router.sheet = .addWant }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if let location = entry.location {
                                Button { router.wantPath.append(.location(location.id)) } label: {
                                    HStack(spacing: 14) {
                                        IconTile(symbol: location.category.symbol)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(location.name).font(BBTheme.display(21)).lineLimit(2)
                                            Text(meta(for: entry, peopleByID: peopleByID))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(minHeight: 70)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Log a Meal Here", systemImage: "plus.circle") { router.sheet = .logMealAt(location.id) }
                                    Button("Remove from Want to Try", systemImage: "bookmark.slash", role: .destructive) {
                                        store.toggleWant(location)
                                        Haptics.selection()
                                    }
                                }
                                .accessibilityHint("Opens restaurant details. More actions are available in the context menu.")
                                if index < entries.count - 1 { Divider() }
                            }
                        }
                    }
                    .editorialCard(padding: 12)
                }
            }
            .padding(.horizontal, BBTheme.Spacing.page)
            .padding(.bottom, 36)
            .readablePageWidth()
        }
        .scrollDismissesKeyboard(.immediately)
        .editorialPage()
        .navigationTitle("Want to Try")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search the list")
        .task(id: query) {
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            effectiveQuery = query
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.sheet = .addWant } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a place")
            }
        }
    }

    private func header(_ count: Int) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Eyebrow("Your next table")
                Text("Want to Try").font(BBTheme.display(37))
                Text("A shared shortlist for wherever you want to eat next.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if count > 0 {
                Text("\(count)")
                    .font(BBTheme.score(36))
                    .foregroundStyle(BBTheme.oxblood)
                    .contentTransition(.numericText())
                    .accessibilityLabel("\(count) saved \(count == 1 ? "place" : "places")")
            }
        }
        .padding(.top, 8)
    }

    private var visibleEntries: [WantEntryEntity] {
        store.wantEntries.filter { entry in
            guard !effectiveQuery.isEmpty else { return true }
            guard let location = entry.location else { return false }
            return ([location.name, location.category.shortTitle, location.city ?? ""] + location.cuisines + location.tags)
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(effectiveQuery)
        }
    }
    private func meta(for entry: WantEntryEntity, peopleByID: [UUID: String]) -> String {
        let person = peopleByID[entry.addedByID] ?? "Someone"
        let category = entry.location?.category.shortTitle ?? "Place"
        return "\(category) · Added by \(person) \(entry.addedAt.formatted(.relative(presentation: .named)))"
    }
}
