import SwiftUI

private struct RankingRowModel: Identifiable {
    let location: RestaurantLocation
    let score: Double
    let provisional: Bool
    let overallRank: Int
    let categoryRank: Int
    let split: Bool
    let myScore: Double?
    let partnerScore: Double?
    var id: UUID { location.id }
}

@MainActor
struct RankingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var scope: RankingScope = .me
    @State private var category: DiningCategory?
    @State private var query = ""
    @State private var effectiveQuery = ""
    @State private var cuisine: String?
    @State private var tag: String?
    @State private var priceBand = 0
    @State private var includesClosed = false

    var body: some View {
        let visibleRows = rows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 17) {
                header
                filters
                if visibleRows.isEmpty { EmptyLedgerView(title: "No ranked places", message: "Try a different filter, or log a meal to begin.", symbol: "list.number") }
                else { ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in rankingRow(row, index: index) } }
            }
            .padding(.horizontal, 16).padding(.bottom, 30).readablePageWidth()
        }
        .editorialPage().navigationTitle("Rankings").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Place, cuisine, or tag")
        .task(id: query) {
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            effectiveQuery = query
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { filterMenu }
            ToolbarItem(placement: .topBarTrailing) { Button { router.sheet = .logMeal } label: { Image(systemName: "plus") } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 15) {
            Eyebrow("Your ranking")
            Text("Where would you go back?").font(BBTheme.display(34))
            if store.partner != nil {
                Picker("Whose ranking", selection: $scope) {
                    Text(store.currentPerson?.name ?? "Me").tag(RankingScope.me)
                    Text(store.partner?.name ?? "Partner").tag(RankingScope.partner)
                    Text("Us").tag(RankingScope.us)
                }.pickerStyle(.segmented).accessibilityIdentifier("ranking-scope")
            }
        }.padding(.top, 8)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", selected: category == nil) { category = nil }
                ForEach(DiningCategory.allCases) { value in chip(value.shortTitle, selected: category == value) { category = value } }
            }.padding(.vertical, 2)
        }.contentMargins(.horizontal, 0)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.callout.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 40).background(selected ? BBTheme.oxblood : BBTheme.ink.opacity(0.06), in: Capsule()).foregroundStyle(selected ? BBTheme.paper : BBTheme.ink) }.buttonStyle(.plain)
    }

    private func rankingRow(_ row: RankingRowModel, index: Int) -> some View {
        Button { router.rankingPath.append(.location(row.id)) } label: {
            HStack(alignment: .center, spacing: 13) {
                Text("\(category == nil ? row.overallRank : row.categoryRank)").font(BBTheme.score(31)).frame(width: 36, alignment: .leading).foregroundStyle(index < 3 ? BBTheme.oxblood : BBTheme.ink)
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.location.name).font(BBTheme.display(21)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(row.location.category.shortTitle)
                        if let cuisine = row.location.cuisines.first { Text("· \(cuisine)") }
                    }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if row.split { RankChip(text: "Split Decision", emphasized: true) }
                }
                Spacer(minLength: 5)
                VStack(alignment: .trailing, spacing: 4) {
                    ScoreMark(score: row.score, size: 37, provisional: row.provisional)
                    if scope == .us, let mine = row.myScore, let theirs = row.partnerScore {
                        Text("\(mine.formatted(.number.precision(.fractionLength(1)))) / \(theirs.formatted(.number.precision(.fractionLength(1))))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .contextMenu {
            Button(store.isWanted(row.location) ? "Remove from Want to Try" : "Add to Want to Try") { store.toggleWant(row.location) }
            Button("Compare directly") { router.sheet = .compare(row.id) }
        }
    }

    private var filterMenu: some View {
        Menu {
            Menu("Cuisine") {
                Button("Any") { cuisine = nil }
                ForEach(allCuisines, id: \.self) { item in Button(item) { cuisine = item } }
            }
            Menu("Tag") {
                Button("Any") { tag = nil }
                ForEach(allTags, id: \.self) { item in Button(item) { tag = item } }
            }
            Menu("Price") {
                Button("Any") { priceBand = 0 }
                ForEach(1...4, id: \.self) { value in Button(String(repeating: "$", count: value)) { priceBand = value } }
            }
            Toggle("Include closed", isOn: $includesClosed)
            Button("Clear filters") { cuisine = nil; tag = nil; priceBand = 0; includesClosed = false }
        } label: { Label("Filters", systemImage: activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
    }

    private var rows: [RankingRowModel] {
        let source: [RankingRowModel]
        switch scope {
        case .me:
            source = store.ranked().map { .init(location: $0.location, score: $0.score, provisional: $0.isProvisional, overallRank: $0.overallRank, categoryRank: $0.categoryRank, split: false, myScore: nil, partnerScore: nil) }
        case .partner:
            source = store.ranked(for: store.partner?.id).map { .init(location: $0.location, score: $0.score, provisional: $0.isProvisional, overallRank: $0.overallRank, categoryRank: $0.categoryRank, split: false, myScore: nil, partnerScore: nil) }
        case .us:
            source = store.coupleRanked().map { .init(location: $0.location, score: $0.score, provisional: $0.isProvisional, overallRank: $0.overallRank, categoryRank: $0.categoryRank, split: $0.isSplitDecision, myScore: $0.myScore.score, partnerScore: $0.partnerScore.score) }
        }
        return source.filter { row in
            let cuisines = row.location.cuisines
            let tags = row.location.tags
            return (category == nil || row.location.category == category) &&
            (includesClosed || !row.location.isClosed) &&
            (cuisine == nil || cuisines.contains(cuisine!)) &&
            (tag == nil || tags.contains(tag!)) &&
            (priceBand == 0 || row.location.visitArray.contains { Int($0.priceBand) == priceBand }) &&
            (effectiveQuery.isEmpty || ([row.location.name] + cuisines + tags).joined(separator: " ").localizedCaseInsensitiveContains(effectiveQuery))
        }
    }
    private var allCuisines: [String] { store.locations.flatMap(\.cuisines).uniqued().sorted() }
    private var allTags: [String] { store.locations.flatMap(\.tags).uniqued().sorted() }
    private var activeFilterCount: Int { [cuisine != nil, tag != nil, priceBand > 0, includesClosed].filter { $0 }.count }
}
