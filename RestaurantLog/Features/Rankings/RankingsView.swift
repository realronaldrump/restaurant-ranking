import SwiftUI

private struct RankingRowModel: Identifiable {
    let id: UUID
    let location: RestaurantLocation
    let diningArea: ResolvedDiningArea?
    let score: Double
    let provisional: Bool
    let overallRank: Int
    let categoryRank: Int
    let split: Bool
    let opinionCount: Int
    let scoreSpread: Double?
    let ratedVisitCount: Int
    let comparisonCount: Int
    let provisionalOpinionCount: Int
    let listScore: Int
    /// The rank a tie shares, resolved once per snapshot rather than by
    /// rescanning every row each time one draws. Both frames are precomputed
    /// because a category tie only ever groups within the row's own category,
    /// so neither value depends on which frame is currently selected.
    var tiedOverallRank: Int?
    var tiedCategoryRank: Int?
}

private struct RankingSnapshotKey: Hashable {
    let revision: Int
    let scope: RankingScope
}

private enum RankingViewMode: String, CaseIterable, Identifiable {
    case ranking = "Ranking"
    case city = "City"

    var id: String { rawValue }
}

private struct CityRankingPlacement {
    let rank: Int
    let isTied: Bool
    let city: String
}

private struct CityRankingSection: Identifiable {
    let id: String
    let title: String
    let rows: [RankingRowModel]
}

@MainActor
struct RankingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scope: RankingScope?
    @State private var category: DiningCategory?
    @State private var hasChosenInitialFrame = false
    @State private var query = ""
    @State private var effectiveQuery = ""
    @State private var cuisine: String?
    @State private var tag: String?
    @State private var priceBand = 0
    @State private var includesClosed = false
    @State private var viewMode: RankingViewMode = .ranking
    @State private var baseRows: [RankingRowModel] = []
    @State private var allCuisines: [String] = []
    @State private var allTags: [String] = []
    @State private var isPreparingRows = true
    @State private var showsScoreExplanation = false

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
        .searchable(text: $query, prompt: "Restaurant, city, cuisine, or tag")
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
                    .accessibilityLabel("Log an outing")
            }
        }
        .editorialPrompt(isPresented: $showsScoreExplanation) {
            EditorialPrompt(
                "How return scores work",
                message: "A return score runs from 0 to 100. Higher means you are more likely to go back. Your reaction sets the starting score, and later outings and comparisons move it. Scores are shown as whole numbers, so restaurants with the same number share a rank.",
                tone: .information,
                actions: [
                    .primary("Settle the Score") {
                        router.rankingPath.append(.settleScore)
                    },
                    .cancel("Got it")
                ]
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Where would you return?")
                    .font(BBTheme.display(28))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { showsScoreExplanation = true } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("How return scores work")
            }
            Text("Higher scores mean you’re more likely to go back.")
                .font(.subheadline)
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
            Picker("Ranking for", selection: scopeBinding) { scopeOptions }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("ranking-scope")
        } else {
            Picker("Ranking for", selection: scopeBinding) { scopeOptions }
                .pickerStyle(.menu)
                .accessibilityIdentifier("ranking-scope")
        }
    }

    @ViewBuilder
    private var scopeOptions: some View {
        ForEach(store.circleMembers) { person in
            Text(person.name).tag(RankingScope.person(person.id))
        }
        Text("Circle").tag(RankingScope.circle)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Eyebrow("Category")
                Spacer()
                Label("Scroll", systemImage: "arrow.left.and.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Categories scroll horizontally")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    FilterChip(title: "Overall", symbol: "square.grid.2x2", selected: category == nil) {
                        hasChosenInitialFrame = true
                        category = nil
                        Haptics.selection()
                    }
                    ForEach(DiningCategory.allCases) { value in
                        FilterChip(title: value.shortTitle, symbol: value.symbol, selected: category == value) {
                            hasChosenInitialFrame = true
                            category = value
                            Haptics.selection()
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .contentMargins(.horizontal, 0)
            .accessibilityLabel("Category, \(category?.shortTitle ?? "overall")")
            .accessibilityHint("Swipe horizontally to rank overall or within one category")
        }
    }

    @ViewBuilder
    private func rankingContent(_ rows: [RankingRowModel]) -> some View {
        if isPreparingRows {
            VStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    HStack { Circle().frame(width: 38, height: 38); VStack(alignment: .leading) { Text("Restaurant name"); Text("Category") }; Spacer(); Text("88") }
                        .frame(minHeight: 64)
                }
            }
            .editorialCard()
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
        } else if rows.isEmpty {
            VStack(spacing: 4) {
                EmptyLogView(
                    title: baseRows.isEmpty ? "Nothing ranked yet" : "No matches",
                    message: baseRows.isEmpty ? "Log an outing with a reaction to start your ranking." : "Clear a filter or try a broader search.",
                    symbol: baseRows.isEmpty ? "list.number" : "line.3.horizontal.decrease.circle"
                )
                if baseRows.isEmpty {
                    Button("Log your first outing") { router.sheet = .logMeal }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Clear filters") { clearFilters(includeCategory: true) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        } else {
            switch viewMode {
            case .ranking:
                scoreRankingContent(rows)
            case .city:
                cityRankingContent(rows)
            }
        }
    }

    @ViewBuilder
    private func scoreRankingContent(_ rows: [RankingRowModel]) -> some View {
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

    private func cityRankingContent(_ rows: [RankingRowModel]) -> some View {
        let placements = cityRankingPlacements
        return ForEach(citySections(for: rows)) { section in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(section.title)
                        .font(BBTheme.score(25))
                        .foregroundStyle(BBTheme.oxblood)
                    Spacer()
                    Text("\(section.rows.count) \(section.rows.count == 1 ? "restaurant" : "restaurants")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        rankingRow(row, cityPlacement: placements[row.id])
                        if index < section.rows.count - 1 { Divider() }
                    }
                }
                .editorialCard(padding: 14)
            }
        }
    }

    private func leaderCard(_ row: RankingRowModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { router.rankingPath.append(.location(row.id, rankingScope: activeScope)) } label: {
                ZStack(alignment: .bottomLeading) {
                    CategoryArtwork(category: row.location.category, height: dynamicTypeSize.isAccessibilitySize ? 270 : 188)
                    LinearGradient(colors: [.clear, .black.opacity(0.68)], startPoint: .top, endPoint: .bottom)
                    leaderCardContent(row)
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
            .accessibilityLabel(rankingAccessibilityLabel(row))

            if row.provisional {
                evidenceButton(row)
            }
        }
    }

    private func rankingRow(_ row: RankingRowModel, cityPlacement: CityRankingPlacement? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { router.rankingPath.append(.location(row.id, rankingScope: activeScope)) } label: {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        accessibleRankingRowContent(row, cityPlacement: cityPlacement)
                    } else {
                        compactRankingRowContent(row, cityPlacement: cityPlacement)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rankingAccessibilityLabel(row, cityPlacement: cityPlacement))

            if row.provisional {
                evidenceButton(row)
                    .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : 51)
                    .padding(.bottom, 8)
            }
        }
        .contextMenu { rankingContextMenu(row) }
    }

    @ViewBuilder
    private func leaderCardContent(_ row: RankingRowModel) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 9) {
                leaderIdentity(row)
                leaderScore(row)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .bottom, spacing: 14) {
                leaderIdentity(row)
                    .layoutPriority(2)
                Spacer(minLength: 8)
                leaderScore(row)
            }
        }
    }

    private func leaderIdentity(_ row: RankingRowModel) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(leaderRankLabel(row), color: BBTheme.cream.opacity(0.82))
            Text(row.location.name)
                .font(BBTheme.display(32))
                .foregroundStyle(BBTheme.cream)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)
            Text(leaderDetail(row))
                .font(.caption)
                .foregroundStyle(BBTheme.cream.opacity(0.72))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        }
    }

    private func leaderScore(_ row: RankingRowModel) -> some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 1) {
            Text("\(listScore(row))")
                .font(BBTheme.score(29))
                .foregroundStyle(BBTheme.cream)
                .contentTransition(.numericText())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("RETURN\nSCORE")
                .font(.caption2.weight(.semibold))
                .tracking(0.4)
                .foregroundStyle(BBTheme.cream.opacity(0.72))
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .lineLimit(2)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func compactRankingRowContent(_ row: RankingRowModel, cityPlacement: CityRankingPlacement?) -> some View {
        HStack(alignment: .center, spacing: 13) {
            rankMark(row, cityPlacement: cityPlacement)
            rankingIdentity(row)
                .layoutPriority(2)
            rankingScore(row)
        }
    }

    private func accessibleRankingRowContent(_ row: RankingRowModel, cityPlacement: CityRankingPlacement?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                rankMark(row, cityPlacement: cityPlacement)
                Text(row.location.name)
                    .font(BBTheme.display(25))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)
            }
            rankingMetadata(row)
            HStack(alignment: .lastTextBaseline) {
                if row.split { RankChip(text: "Opinions vary") }
                Spacer(minLength: 8)
                rankingScore(row)
            }
        }
    }

    private func rankMark(_ row: RankingRowModel, cityPlacement: CityRankingPlacement? = nil) -> some View {
        Text(rankMarker(row, cityPlacement: cityPlacement))
            .font(BBTheme.score(21))
            .foregroundStyle(displayedRank(row, cityPlacement: cityPlacement) <= 3 ? BBTheme.oxblood : BBTheme.ink)
            .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 38, alignment: .center)
            .accessibilityLabel(rankAccessibilityLabel(row, cityPlacement: cityPlacement))
    }

    private func rankingIdentity(_ row: RankingRowModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.location.name)
                .font(BBTheme.display(25))
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .allowsTightening(true)
                .layoutPriority(2)
            rankingMetadata(row)
            if row.split { RankChip(text: "Opinions vary") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rankingMetadata(_ row: RankingRowModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.location.category.shortTitle)
                if let cuisine = row.location.cuisines.first { Text("· \(cuisine)") }
            }
            if row.opinionCount > 1, let spread = row.scoreSpread {
                Text("\(row.opinionCount) opinions · \(spread.formatted(.number.precision(.fractionLength(0))))-point range")
                    .font(.caption2)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func rankingScore(_ row: RankingRowModel) -> some View {
        Text("\(listScore(row))")
            .font(BBTheme.score(23))
            .foregroundStyle(BBTheme.oxblood)
            .contentTransition(.numericText())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 44, alignment: .trailing)
    }

    private func evidenceButton(_ row: RankingRowModel) -> some View {
        Button {
            router.rankingPath.append(.settleScore)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                Text(earlyScoreSummary(row))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                Text("Compare")
                    .fontWeight(.bold)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
            }
            .font(.caption)
            .foregroundStyle(BBTheme.oxblood)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(BBTheme.oxblood.opacity(0.07), in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.location.name), \(earlyScoreSummary(row)), compare")
        .accessibilityHint("Opens Settle the Score")
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
            VStack(alignment: .leading, spacing: 2) {
                Text(isPreparingRows ? "Updating ranking…" : "\(count) \(count == 1 ? "restaurant" : "restaurants")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(rankContextLabel)
                    .font(.caption2.weight(.bold))
                    .tracking(0.35)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if totalFilterCount > 0 {
                Button("Clear all") { clearFilters(includeCategory: true) }
                    .font(.caption.weight(.bold))
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            }
            rankingViewMenu
        }
        .frame(minHeight: 32)
    }

    private var rankingViewMenu: some View {
        Menu {
            ForEach(RankingViewMode.allCases) { mode in
                Button {
                    viewMode = mode
                    Haptics.selection()
                } label: {
                    Label(mode.rawValue, systemImage: viewMode == mode ? "checkmark" : "arrow.up.arrow.down")
                }
            }
        } label: {
            Label(viewMode.rawValue, systemImage: viewMode == .city ? "building.2" : "list.number")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(BBTheme.surface, in: Capsule())
                .overlay(Capsule().stroke(BBTheme.hairline))
        }
        .accessibilityLabel("Rankings view, \(viewMode.rawValue)")
        .accessibilityIdentifier("ranking-view")
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
        let locations = store.locations
        let resolvedAreas = DiningAreaResolver.resolve(locations: locations)
        let source: [RankingRowModel]
        switch activeScope {
        case .person(let personID):
            source = store.ranked(for: personID).map {
                .init(
                    id: $0.id, location: $0.location, diningArea: resolvedAreas[$0.id], score: $0.score,
                    provisional: $0.isProvisional, overallRank: $0.overallRank,
                    categoryRank: $0.categoryRank, split: false,
                    opinionCount: 1, scoreSpread: nil,
                    ratedVisitCount: $0.ratedVisitCount,
                    comparisonCount: $0.comparisonCount,
                    provisionalOpinionCount: $0.isProvisional ? 1 : 0,
                    listScore: $0.listScore
                )
            }
        case .circle:
            source = store.circleRanked().map {
                .init(
                    id: $0.id, location: $0.location, diningArea: resolvedAreas[$0.id], score: $0.score,
                    provisional: $0.isProvisional, overallRank: $0.overallRank,
                    categoryRank: $0.categoryRank, split: $0.isSplitDecision,
                    opinionCount: $0.memberScores.count, scoreSpread: $0.scoreSpread,
                    ratedVisitCount: $0.memberScores.reduce(0) { $0 + $1.score.ratedVisitCount },
                    comparisonCount: $0.memberScores.reduce(0) { $0 + $1.score.comparisonCount },
                    provisionalOpinionCount: $0.memberScores.filter { $0.score.isProvisional }.count,
                    listScore: $0.listScore
                )
            }
        }
        baseRows = resolvingTiedRanks(source)
        if !hasChosenInitialFrame, let openingFrame = openingFrame(for: source) {
            category = openingFrame
            hasChosenInitialFrame = true
        }
        allCuisines = locations.flatMap(\.cuisines).uniqued().sorted()
        allTags = locations.flatMap(\.tags).uniqued().sorted()
        isPreparingRows = false
    }

    private var filteredRows: [RankingRowModel] {
        baseRows.filter { row in
            let cuisines = row.location.cuisines
            let tags = row.location.tags
            let cityValues = [row.diningArea?.name, normalizedCity(row.location.city)]
            return (category == nil || row.location.category == category) &&
            (includesClosed || !row.location.isClosed) &&
            (cuisine.map(cuisines.contains) ?? true) &&
            (tag.map(tags.contains) ?? true) &&
            (priceBand == 0 || row.location.hasVisit(inPriceBand: priceBand)) &&
            (effectiveQuery.isEmpty || ([row.location.name] + cityValues + cuisines.map(Optional.some) + tags.map(Optional.some))
                .compactMap { $0 }
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(effectiveQuery))
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
            hasChosenInitialFrame = true
            category = nil
            query = ""
            effectiveQuery = ""
        }
        Haptics.selection()
    }

    private func displayedRank(_ row: RankingRowModel, cityPlacement: CityRankingPlacement? = nil) -> Int {
        if let cityPlacement { return cityPlacement.rank }
        return category == nil ? row.overallRank : row.categoryRank
    }

    private func listScore(_ row: RankingRowModel) -> Int { row.listScore }

    private func tiedRank(_ row: RankingRowModel) -> Int? {
        category == nil ? row.tiedOverallRank : row.tiedCategoryRank
    }

    /// Fills in the tie markers for a freshly built snapshot in two passes
    /// rather than rescanning the list once per row per draw.
    private func resolvingTiedRanks(_ rows: [RankingRowModel]) -> [RankingRowModel] {
        var lowestOverallRank: [Int: Int] = [:]
        var overallTieCount: [Int: Int] = [:]
        var lowestCategoryRank: [DiningCategory: [Int: Int]] = [:]
        var categoryTieCount: [DiningCategory: [Int: Int]] = [:]

        for row in rows {
            overallTieCount[row.listScore, default: 0] += 1
            lowestOverallRank[row.listScore] = min(
                lowestOverallRank[row.listScore] ?? row.overallRank,
                row.overallRank
            )
            let category = row.location.category
            categoryTieCount[category, default: [:]][row.listScore, default: 0] += 1
            lowestCategoryRank[category, default: [:]][row.listScore] = min(
                lowestCategoryRank[category]?[row.listScore] ?? row.categoryRank,
                row.categoryRank
            )
        }

        return rows.map { row in
            var resolved = row
            if overallTieCount[row.listScore, default: 0] > 1 {
                resolved.tiedOverallRank = lowestOverallRank[row.listScore]
            }
            let category = row.location.category
            if categoryTieCount[category]?[row.listScore, default: 0] ?? 0 > 1 {
                resolved.tiedCategoryRank = lowestCategoryRank[category]?[row.listScore]
            }
            return resolved
        }
    }

    /// The frame the ranking opens in.
    ///
    /// Category ranking is the honest default — a return list that mixes ice
    /// cream with steakhouses answers a question nobody asked. But opening on
    /// whichever category happens to hold the top overall spot can land on a
    /// one-restaurant list, so this picks the category the person actually eats
    /// in most, and falls back to Overall when nothing stands out.
    private func openingFrame(for rows: [RankingRowModel]) -> DiningCategory? {
        guard rows.count > 1 else { return nil }
        var counts: [DiningCategory: Int] = [:]
        for row in rows { counts[row.location.category, default: 0] += 1 }
        let densest = DiningCategory.allCases
            .compactMap { category in counts[category].map { (category, $0) } }
            .max { lhs, rhs in lhs.1 < rhs.1 }
        guard let densest, densest.1 > 1 else { return nil }
        return densest.0
    }

    private func rankMarker(_ row: RankingRowModel, cityPlacement: CityRankingPlacement? = nil) -> String {
        if let cityPlacement {
            return cityPlacement.isTied ? "=\(cityPlacement.rank)" : "\(cityPlacement.rank)"
        }
        return tiedRank(row).map { "=\($0)" } ?? "\(displayedRank(row))"
    }

    private func rankAccessibilityLabel(_ row: RankingRowModel, cityPlacement: CityRankingPlacement? = nil) -> String {
        if let cityPlacement {
            return cityPlacement.isTied
                ? "Tied at rank \(cityPlacement.rank) in \(cityPlacement.city)"
                : "Rank \(cityPlacement.rank) in \(cityPlacement.city)"
        }
        let context = category == nil ? "overall" : "in \(row.location.category.shortTitle)"
        if let tiedRank = tiedRank(row) {
            return "Tied at rank \(tiedRank) \(context)"
        }
        return "Rank \(displayedRank(row)) \(context)"
    }

    private func rankingAccessibilityLabel(_ row: RankingRowModel, cityPlacement: CityRankingPlacement? = nil) -> String {
        "\(rankAccessibilityLabel(row, cityPlacement: cityPlacement)), \(row.location.name), return score \(listScore(row)) out of 100\(row.provisional ? ", early score" : "")"
    }

    private func earlyScoreSummary(_ row: RankingRowModel) -> String {
        if case .circle = activeScope {
            return row.provisionalOpinionCount == 1
                ? "1 early score"
                : "\(row.provisionalOpinionCount) early scores"
        }
        if row.ratedVisitCount == 1, row.comparisonCount == 1 { return "Based on 1 outing and 1 comparison" }
        if row.ratedVisitCount == 1, row.comparisonCount > 1 { return "Based on 1 outing and \(row.comparisonCount) comparisons" }
        if row.ratedVisitCount == 1 { return "Based on 1 outing" }
        if row.comparisonCount == 1 { return "Based on 1 comparison" }
        if row.comparisonCount > 1 { return "Based on \(row.comparisonCount) comparisons" }
        return "Early score"
    }

    private var rankContextLabel: String {
        if viewMode == .city {
            return category.map { "RANKED BY CITY · \($0.shortTitle.uppercased())" } ?? "RANKED BY CITY"
        }
        return category.map { "RANKED IN \($0.shortTitle.uppercased())" } ?? "RANKED OVERALL"
    }

    private func leaderDetail(_ row: RankingRowModel) -> String {
        ([row.location.category.shortTitle] + Array(row.location.cuisines.prefix(1))).joined(separator: " · ")
    }

    private func leaderRankLabel(_ row: RankingRowModel) -> String {
        let rank = tiedRank(row) ?? displayedRank(row)
        let list = category == nil ? "overall" : row.location.category.shortTitle
        let placement = tiedRank(row) == nil ? "#\(rank) \(list)" : "Tied #\(rank) \(list)"
        return hasResultNarrowingFilters ? "Top match · \(placement)" : placement
    }

    private var hasResultNarrowingFilters: Bool {
        activeFilterCount > 0 || !effectiveQuery.isEmpty
    }

    private var cityRankingPlacements: [UUID: CityRankingPlacement] {
        let frameRows = baseRows.filter { category == nil || $0.location.category == category }
        let grouped = Dictionary(grouping: frameRows, by: citySortKey)
        var result: [UUID: CityRankingPlacement] = [:]
        for rows in grouped.values {
            let scoreCounts = Dictionary(grouping: rows, by: \.listScore).mapValues(\.count)
            var firstRankByScore: [Int: Int] = [:]
            for (index, row) in rows.enumerated() {
                let rank = firstRankByScore[row.listScore] ?? (index + 1)
                firstRankByScore[row.listScore] = rank
                result[row.id] = CityRankingPlacement(
                    rank: rank,
                    isTied: scoreCounts[row.listScore, default: 0] > 1,
                    city: row.diningArea?.name ?? "City unknown"
                )
            }
        }
        return result
    }

    private func citySections(for rows: [RankingRowModel]) -> [CityRankingSection] {
        let grouped = Dictionary(grouping: rows, by: citySortKey)
        return grouped.keys.sorted(by: cityKeyComesBefore).map { key in
            let cityRows = grouped[key] ?? []
            return CityRankingSection(
                id: "city:\(key)",
                title: cityRows.first?.diningArea?.name ?? "City unknown",
                rows: cityRows
            )
        }
    }

    private func citySortKey(_ row: RankingRowModel) -> String {
        row.diningArea?.id ?? ""
    }

    private func cityKeyComesBefore(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.isEmpty { return false }
        if rhs.isEmpty { return true }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private func normalizedCity(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var activeScope: RankingScope {
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

    private var scopeBinding: Binding<RankingScope> {
        Binding(get: { activeScope }, set: { scope = $0 })
    }

}
