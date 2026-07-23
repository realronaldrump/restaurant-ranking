import SwiftUI

private struct RankingRowModel: Identifiable {
    let id: UUID
    let location: RestaurantLocation
    let score: Double
    let provisional: Bool
    let overallRank: Int
    let categoryRank: Int
    let split: Bool
    let opinionCount: Int
    let scoreSpread: Double?
}

private enum RankingSelection: Hashable {
    case person(UUID)
    case circle
}

private struct RankingSnapshotKey: Hashable {
    let revision: Int
    let scope: RankingSelection
}

@MainActor
struct RankingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var scope: RankingSelection?
    @State private var category: DiningCategory?
    @State private var query = ""
    @State private var effectiveQuery = ""
    @State private var cuisine: String?
    @State private var tag: String?
    @State private var priceBand = 0
    @State private var includesClosed = false
    @State private var baseRows: [RankingRowModel] = []
    @State private var allCuisines: [String] = []
    @State private var allTags: [String] = []
    @State private var isPreparingRows = true

    var body: some View {
        let visibleRows = filteredRows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                filters
                resultSummary(visibleRows.count)
                rankingContent(visibleRows)
            }
            .padding(.horizontal, BBTheme.Spacing.page)
            .padding(.bottom, 36)
            .readablePageWidth()
        }
        .scrollDismissesKeyboard(.immediately)
        .editorialPage()
        .navigationTitle("Rankings")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Place, cuisine, or tag")
        .task(id: query) {
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            effectiveQuery = query
        }
        .task(id: RankingSnapshotKey(revision: store.revision, scope: activeScope)) {
            rebuildSnapshot()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { filterMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.sheet = .logMeal } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Log a meal")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 15) {
            Eyebrow(scopeTitle)
            Text("Where would you return?")
                .font(BBTheme.display(35))
                .fixedSize(horizontal: false, vertical: true)
            Text("A living order shaped by every reaction and comparison.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.circleMembers.count > 1 {
                scopePicker
                    .padding(5)
                    .background(BBTheme.surface, in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous))
            }
        }.padding(.top, 8)
    }

    @ViewBuilder
    private var scopePicker: some View {
        if store.circleMembers.count <= 2 {
            Picker("Whose ranking", selection: scopeBinding) { scopeOptions }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("ranking-scope")
        } else {
            Picker("Whose ranking", selection: scopeBinding) { scopeOptions }
                .pickerStyle(.menu)
                .accessibilityIdentifier("ranking-scope")
        }
    }

    @ViewBuilder
    private var scopeOptions: some View {
        ForEach(store.circleMembers) { person in
            Text(person.name).tag(RankingSelection.person(person.id))
        }
        Text("Circle").tag(RankingSelection.circle)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                FilterChip(title: "All", symbol: "square.grid.2x2", selected: category == nil) {
                    category = nil
                    Haptics.selection()
                }
                ForEach(DiningCategory.allCases) { value in
                    FilterChip(title: value.shortTitle, symbol: value.symbol, selected: category == value) {
                        category = value
                        Haptics.selection()
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .contentMargins(.horizontal, 0)
    }

    @ViewBuilder
    private func rankingContent(_ rows: [RankingRowModel]) -> some View {
        if isPreparingRows {
            VStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    HStack { Circle().frame(width: 38, height: 38); VStack(alignment: .leading) { Text("Restaurant name"); Text("Category") }; Spacer(); Text("88.8") }
                        .frame(minHeight: 64)
                }
            }
            .editorialCard()
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
        } else if rows.isEmpty {
            VStack(spacing: 4) {
                EmptyLogView(
                    title: baseRows.isEmpty ? "No ranked places yet" : "No matches here",
                    message: baseRows.isEmpty ? "Log a reaction and your return list will begin." : "Clear a filter or try a broader search.",
                    symbol: baseRows.isEmpty ? "list.number" : "line.3.horizontal.decrease.circle"
                )
                if baseRows.isEmpty {
                    Button("Log Your First Meal") { router.sheet = .logMeal }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Clear Filters") { clearFilters(includeCategory: true) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        } else {
            if let first = rows.first { leaderCard(first) }
            if rows.count > 1 {
                VStack(spacing: 0) {
                    ForEach(Array(rows.dropFirst().enumerated()), id: \.element.id) { index, row in
                        rankingRow(row)
                        if index < rows.count - 2 { Divider() }
                    }
                }
                .editorialCard(padding: 14)
            }
        }
    }

    private func leaderCard(_ row: RankingRowModel) -> some View {
        Button { router.rankingPath.append(.location(row.id)) } label: {
            ZStack(alignment: .bottomLeading) {
                CategoryArtwork(category: row.location.category, height: 188)
                LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Eyebrow(
                            category == nil ? "#1 overall" : "#1 \(row.location.category.shortTitle)",
                            color: BBTheme.cream.opacity(0.82)
                        )
                        Text(row.location.name)
                            .font(BBTheme.display(28))
                            .foregroundStyle(BBTheme.cream)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(leaderDetail(row))
                            .font(.caption)
                            .foregroundStyle(BBTheme.cream.opacity(0.72))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(row.score.formatted(.number.precision(.fractionLength(1))))
                            .font(BBTheme.score(45))
                            .foregroundStyle(BBTheme.cream)
                        if row.provisional {
                            Text("PROVISIONAL").font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(BBTheme.cream.opacity(0.72))
                        }
                    }
                }
                .padding(18)
            }
            .clipShape(RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous)
                    .stroke(BBTheme.cream.opacity(0.13), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(.pressable)
        .contextMenu { rankingContextMenu(row) }
        .accessibilityLabel("Number one, \(row.location.name), score \(row.score.formatted(.number.precision(.fractionLength(1))))")
    }

    private func rankingRow(_ row: RankingRowModel) -> some View {
        Button { router.rankingPath.append(.location(row.id)) } label: {
            HStack(alignment: .center, spacing: 13) {
                Text("\(displayedRank(row))")
                    .font(BBTheme.score(25))
                    .foregroundStyle(displayedRank(row) <= 3 ? BBTheme.oxblood : BBTheme.ink)
                    .frame(width: 38, alignment: .center)
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
                    if row.opinionCount > 1, let spread = row.scoreSpread {
                        Text("\(row.opinionCount) opinions · \(spread.formatted(.number.precision(.fractionLength(1)))) spread")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 72)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { rankingContextMenu(row) }
    }

    @ViewBuilder
    private func rankingContextMenu(_ row: RankingRowModel) -> some View {
        Button(store.isWanted(row.location) ? "Remove from Want to Try" : "Add to Want to Try") {
            store.toggleWant(row.location)
        }
        Button("Compare directly") { router.sheet = .compare(row.id) }
    }

    private func resultSummary(_ count: Int) -> some View {
        HStack(spacing: 10) {
            Text(isPreparingRows ? "Updating ranking…" : "\(count) \(count == 1 ? "place" : "places")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if totalFilterCount > 0 {
                Button("Clear all") { clearFilters(includeCategory: true) }
                    .font(.caption.weight(.bold))
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            }
        }
        .frame(minHeight: 32)
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
            Button("Clear advanced filters") { clearFilters(includeCategory: false) }
                .disabled(activeFilterCount == 0)
        } label: {
            Label("Filters", systemImage: activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(activeFilterCount == 0 ? "Filters" : "Filters, \(activeFilterCount) active")
    }

    private func rebuildSnapshot() {
        isPreparingRows = true
        let source: [RankingRowModel]
        switch activeScope {
        case .person(let personID):
            source = store.ranked(for: personID).map {
                .init(
                    id: $0.id, location: $0.location, score: $0.score,
                    provisional: $0.isProvisional, overallRank: $0.overallRank,
                    categoryRank: $0.categoryRank, split: false,
                    opinionCount: 1, scoreSpread: nil
                )
            }
        case .circle:
            source = store.circleRanked().map {
                .init(
                    id: $0.id, location: $0.location, score: $0.score,
                    provisional: $0.isProvisional, overallRank: $0.overallRank,
                    categoryRank: $0.categoryRank, split: $0.isSplitDecision,
                    opinionCount: $0.memberScores.count, scoreSpread: $0.scoreSpread
                )
            }
        }
        baseRows = source
        let locations = store.locations
        allCuisines = locations.flatMap(\.cuisines).uniqued().sorted()
        allTags = locations.flatMap(\.tags).uniqued().sorted()
        isPreparingRows = false
    }

    private var filteredRows: [RankingRowModel] {
        baseRows.filter { row in
            let cuisines = row.location.cuisines
            let tags = row.location.tags
            return (category == nil || row.location.category == category) &&
            (includesClosed || !row.location.isClosed) &&
            (cuisine.map(cuisines.contains) ?? true) &&
            (tag.map(tags.contains) ?? true) &&
            (priceBand == 0 || row.location.hasVisit(inPriceBand: priceBand)) &&
            (effectiveQuery.isEmpty || ([row.location.name] + cuisines + tags).joined(separator: " ").localizedCaseInsensitiveContains(effectiveQuery))
        }
    }
    private var activeFilterCount: Int { [cuisine != nil, tag != nil, priceBand > 0, includesClosed].filter { $0 }.count }
    private var totalFilterCount: Int { activeFilterCount + (category == nil ? 0 : 1) + (effectiveQuery.isEmpty ? 0 : 1) }

    private func clearFilters(includeCategory: Bool) {
        cuisine = nil
        tag = nil
        priceBand = 0
        includesClosed = false
        if includeCategory {
            category = nil
            query = ""
            effectiveQuery = ""
        }
        Haptics.selection()
    }

    private func displayedRank(_ row: RankingRowModel) -> Int {
        category == nil ? row.overallRank : row.categoryRank
    }

    private func leaderDetail(_ row: RankingRowModel) -> String {
        ([row.location.category.shortTitle] + Array(row.location.cuisines.prefix(1))).joined(separator: " · ")
    }

    private var activeScope: RankingSelection {
        if let scope {
            switch scope {
            case .circle where store.circleMembers.count > 1:
                return scope
            case .person(let id) where store.circleMembers.contains(where: { $0.id == id }):
                return scope
            default:
                break
            }
        }
        if let currentID = store.currentPerson?.id { return .person(currentID) }
        if let firstID = store.circleMembers.first?.id { return .person(firstID) }
        return .circle
    }

    private var scopeBinding: Binding<RankingSelection> {
        Binding(get: { activeScope }, set: { scope = $0 })
    }

    private var scopeTitle: String {
        switch activeScope {
        case .circle:
            return "Circle ranking"
        case .person(let id):
            let name = store.person(id: id)?.name ?? "Personal"
            return "\(name)’s ranking"
        }
    }
}
