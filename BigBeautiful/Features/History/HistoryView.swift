import SwiftUI

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All", unrated = "Unrated", hazy = "Hazy", shared = "Shared", closed = "Closed"
    var id: String { rawValue }
}

@MainActor
struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var filter: HistoryFilter = .all

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading) { Eyebrow("Every visit, permanent"); Text("The complete record").font(BBTheme.display(34)) }
                    Spacer(); Text("\(filtered.count)").font(BBTheme.score(35)).foregroundStyle(BBTheme.oxblood)
                }.padding(.top, 7)
                Picker("History filter", selection: $filter) { ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                if filtered.isEmpty { EmptyLedgerView(title: "Nothing in this chapter", message: query.isEmpty ? "Your meals will appear here as you log them." : "No visit matches that search.", symbol: "book.pages") }
                ForEach(groupedYears, id: \.year) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(group.year)).font(BBTheme.score(24)).foregroundStyle(BBTheme.oxblood)
                        ForEach(group.visits) { visit in
                            Button { router.historyPath.append(.visit(visit.id)) } label: { VisitRow(visit: visit) }.buttonStyle(.plain)
                            if visit.id != group.visits.last?.id { Divider() }
                        }
                    }.ledgerCard()
                }
            }.padding(.horizontal, 16).padding(.bottom, 30).readablePageWidth()
        }
        .editorialPage().navigationTitle("History").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Place, dish, companion, or memory")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { router.historyPath.append(.backfill) } label: { Label("Backfill", systemImage: "photo.on.rectangle.angled") } }
            ToolbarItem(placement: .topBarTrailing) { Button { router.sheet = .logMeal } label: { Image(systemName: "plus") } }
        }
    }

    private var filtered: [VisitEntity] {
        store.visits.filter { visit in
            let filterMatches: Bool = switch filter {
            case .all: true
            case .unrated: visit.ratingArray.isEmpty
            case .hazy: visit.ratingArray.contains(where: \.hazyMemory)
            case .shared: visit.isShared
            case .closed: visit.location?.isClosed == true
            }
            guard filterMatches else { return false }
            guard !query.isEmpty else { return true }
            let people = visit.companionIDs.compactMap { id in store.people.first(where: { $0.id == id })?.name }
            let searchable = [visit.location?.name, visit.location?.city, visit.memory] + visit.dishEntryArray.map { $0.dish?.name } + people.map(Optional.some)
            return searchable.compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }

    private var groupedYears: [(year: Int, visits: [VisitEntity])] {
        let grouped = Dictionary(grouping: filtered) { Calendar.current.component(.year, from: $0.date) }
        return grouped.map { ($0.key, $0.value.sorted { $0.date > $1.date }) }.sorted { $0.year > $1.year }
    }
}
