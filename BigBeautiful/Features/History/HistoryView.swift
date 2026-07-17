import SwiftUI

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All", unrated = "Unrated", hazy = "Hazy", shared = "Shared", closed = "Closed"
    var id: String { rawValue }
}

private enum HistoryListItem: Identifiable {
    case year(Int)
    case visit(VisitEntity)

    var id: String {
        switch self {
        case .year(let year): "year-\(year)"
        case .visit(let visit): "visit-\(visit.id.uuidString)"
        }
    }
}

private struct HistorySnapshot {
    let count: Int
    let items: [HistoryListItem]
}

@MainActor
struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var effectiveQuery = ""
    @State private var filter: HistoryFilter = .all

    var body: some View {
        let snapshot = historySnapshot
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading) { Eyebrow("By date"); Text("Every visit").font(BBTheme.display(34)) }
                    Spacer(); Text("\(snapshot.count)").font(BBTheme.score(35)).foregroundStyle(BBTheme.oxblood)
                }.padding(.top, 7)
                Picker("History filter", selection: $filter) { ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                if snapshot.count == 0 {
                    EmptyLedgerView(
                        title: query.isEmpty ? "No visits yet" : "No matching visits",
                        message: query.isEmpty ? "Meals will appear here after you log them." : "Try a different search.",
                        symbol: "book.pages"
                    )
                }
                ForEach(snapshot.items) { item in
                    switch item {
                    case .year(let year):
                        Text(String(year)).font(BBTheme.score(24)).foregroundStyle(BBTheme.oxblood)
                    case .visit(let visit):
                        Button { router.historyPath.append(.visit(visit.id)) } label: { VisitRow(visit: visit) }
                            .buttonStyle(.plain)
                            .ledgerCard(padding: 14)
                    }
                }
            }.padding(.horizontal, 16).padding(.bottom, 30).readablePageWidth()
        }
        .editorialPage().navigationTitle("History").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Place, dish, companion, or memory")
        .task(id: query) {
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            effectiveQuery = query
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { router.historyPath.append(.backfill) } label: { Label("Backfill", systemImage: "photo.on.rectangle.angled") } }
            ToolbarItem(placement: .topBarTrailing) { Button { router.sheet = .logMeal } label: { Image(systemName: "plus") } }
        }
    }

    private var historySnapshot: HistorySnapshot {
        let peopleByID = Dictionary(uniqueKeysWithValues: store.people.map { ($0.id, $0.name) })
        let visits = store.visits.filter { visit in
            let filterMatches: Bool = switch filter {
            case .all: true
            case .unrated: visit.ratingArray.isEmpty
            case .hazy: visit.ratingArray.contains(where: \.hazyMemory)
            case .shared: visit.isShared
            case .closed: visit.location?.isClosed == true
            }
            guard filterMatches else { return false }
            guard !effectiveQuery.isEmpty else { return true }
            let people = visit.companionIDs.compactMap { peopleByID[$0] }
            let searchable = [visit.location?.name, visit.location?.city, visit.memory]
                + visit.dishEntryArray.map { $0.dish?.name }
                + people.map(Optional.some)
            return searchable.compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(effectiveQuery)
        }
        let grouped = Dictionary(grouping: visits) { Calendar.current.component(.year, from: $0.date) }
        let items = grouped.keys.sorted(by: >).flatMap { year -> [HistoryListItem] in
            [.year(year)] + (grouped[year] ?? []).map(HistoryListItem.visit)
        }
        return .init(count: visits.count, items: items)
    }
}
