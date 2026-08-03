import SwiftUI

enum StatsDrilldown: Hashable {
    case outings
    case restaurants
    case dishes
    case cities
    case city(String)
    case reaction(String)
    case disagreements
    case categories
    case category(String)
    case repeatOutings
    case memories
}

private struct StatsCategoryLeader: Identifiable {
    let category: DiningCategory
    let score: LocationScore
    var id: DiningCategory { category }
}

private struct StatsSnapshot {
    let visitCount: Int
    let locationCount: Int
    let dishCount: Int
    let cityCount: Int
    let reactionCounts: [Reaction: Int]
    let ratingCount: Int
    let contested: [CircleLocationScore]
    let categoryLeaders: [StatsCategoryLeader]
    let returnVisitCount: Int
    let memoryCount: Int
}

private struct StatsCitySummary: Identifiable {
    let id: String
    let name: String
    let locations: [RestaurantLocation]

    var visitCount: Int { locations.reduce(0) { $0 + $1.visitArray.count } }
    var dishCount: Int { locations.reduce(0) { $0 + $1.dishArray.count } }
}

private struct StatsCategorySummary: Identifiable {
    let category: DiningCategory
    let locations: [RestaurantLocation]

    var id: String { category.rawValue }
    var visitCount: Int { locations.reduce(0) { $0 + $1.visitArray.count } }
}

private struct StatsDishSummary: Identifiable {
    let dish: DishEntity
    let location: RestaurantLocation

    var id: UUID { dish.id }
}

@MainActor
struct StatsView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        let snapshot = statsSnapshot
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Statistics").font(BBTheme.display(37))
                    Text(isShared ? "Totals for the whole circle, plus your own reactions and where people disagree." : "Totals across every outing you have logged.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                metricGrid(snapshot)
                reactionDistribution(snapshot)
                contested(snapshot.contested)
                categoryLeaders(snapshot.categoryLeaders)
                memoryStats(snapshot)
            }
            .padding(BBTheme.Spacing.page)
            .padding(.bottom, 28)
            .readablePageWidth()
        }
        .editorialPage()
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func metricGrid(_ snapshot: StatsSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
            metric(snapshot.visitCount, "outings", symbol: "calendar", destination: .outings)
            metric(snapshot.locationCount, "restaurants", symbol: "fork.knife", destination: .restaurants)
            metric(snapshot.dishCount, "dishes", symbol: "takeoutbag.and.cup.and.straw", destination: .dishes)
            metric(snapshot.cityCount, "cities", symbol: "building.2", destination: .cities)
        }
    }

    private func metric(_ value: Int, _ title: String, symbol: String, destination: StatsDrilldown) -> some View {
        Button { open(destination) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(BBTheme.oxblood)
                        .frame(width: 32, height: 32)
                        .background(BBTheme.oxblood.opacity(0.08), in: Circle())
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("\(value)").font(BBTheme.score(43)).foregroundStyle(BBTheme.oxblood)
                Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .editorialCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(title)")
        .accessibilityHint("Shows the \(title) breakdown")
    }

    private func reactionDistribution(_ snapshot: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            EditorialSectionHeader("Your reactions")
            ForEach(Array(Reaction.allCases.enumerated()), id: \.element.id) { index, reaction in
                let count = snapshot.reactionCounts[reaction] ?? 0
                Button { open(.reaction(reaction.rawValue)) } label: {
                    VStack(spacing: 7) {
                        HStack {
                            Label(reaction.title, systemImage: reaction.symbol)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(count), total: Double(max(1, snapshot.ratingCount)))
                            .tint(BBTheme.oxblood)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(reaction.title), \(count) of \(snapshot.ratingCount) reactions")
                .accessibilityHint("Shows outings with this reaction")
                if index < Reaction.allCases.count - 1 { Divider() }
            }
        }
        .editorialCard()
    }

    @ViewBuilder private func contested(_ split: [CircleLocationScore]) -> some View {
        if !split.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader(
                    "Where you disagree",
                    actionTitle: split.count > 5 ? "See all" : "Explore"
                ) { open(.disagreements) }
                ForEach(Array(split.prefix(5).enumerated()), id: \.element.id) { index, item in
                    let ordered = item.memberScores.sorted { $0.score.score < $1.score.score }
                    let lowest = ordered.first
                    let highest = ordered.last
                    Button { router.morePath.append(.location(item.id, rankingScope: .circle)) } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: "arrow.left.and.right", emphasized: true)
                            VStack(alignment: .leading) {
                                Text(item.location.name).font(.headline)
                                Text(disagreementDescription(lowest: lowest, highest: highest, spread: item.scoreSpread))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Text("\(lowest.map { "\($0.score.listScore)" } ?? "—")–\(highest.map { "\($0.score.listScore)" } ?? "—")")
                                .font(BBTheme.score(19)).foregroundStyle(BBTheme.oxblood)
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 62)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < min(split.count, 5) - 1 { Divider() }
                }
            }
            .editorialCard()
        }
    }

    @ViewBuilder private func categoryLeaders(_ leaders: [StatsCategoryLeader]) -> some View {
        if !leaders.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Top in each category", actionTitle: "Breakdown") { open(.categories) }
                ForEach(Array(leaders.enumerated()), id: \.element.id) { index, leader in
                    Button { router.morePath.append(.location(leader.score.id, rankingScope: store.currentPerson.map { .person($0.id) })) } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: leader.category.symbol)
                            VStack(alignment: .leading) {
                                Text(leader.category.shortTitle).font(.caption).foregroundStyle(.secondary)
                                Text(leader.score.location.name).font(.headline)
                            }
                            Spacer(minLength: 8)
                            Text("\(leader.score.listScore)").font(BBTheme.score(22))
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 62)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < leaders.count - 1 { Divider() }
                }
            }
            .editorialCard()
        }
    }

    private func memoryStats(_ snapshot: StatsSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                memoryMetric(snapshot.returnVisitCount, "REPEAT OUTINGS", symbol: "repeat", destination: .repeatOutings)
                Divider()
                memoryMetric(snapshot.memoryCount, "MEMORIES", symbol: "quote.opening", destination: .memories)
            }
            VStack(spacing: 12) {
                memoryMetric(snapshot.returnVisitCount, "REPEAT OUTINGS", symbol: "repeat", destination: .repeatOutings)
                Divider()
                memoryMetric(snapshot.memoryCount, "MEMORIES", symbol: "quote.opening", destination: .memories)
            }
        }
        .editorialCard()
    }

    private func memoryMetric(_ value: Int, _ title: String, symbol: String, destination: StatsDrilldown) -> some View {
        Button { open(destination) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(value)").font(BBTheme.score(35))
                    Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: symbol).foregroundStyle(BBTheme.oxblood)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the \(title.lowercased()) breakdown")
    }

    private var statsSnapshot: StatsSnapshot {
        let visits = store.visits
        let locations = store.locations
        let personID = store.currentPerson?.id
        var reactionCounts: [Reaction: Int] = [:]
        var ratingCount = 0
        var memoryCount = 0
        for visit in visits {
            if let personID, store.memory(for: visit, personID: personID)?.isEmpty == false {
                memoryCount += 1
            }
            if let personID, let rating = visit.rating(for: personID) {
                reactionCounts[rating.reaction, default: 0] += 1
                ratingCount += 1
            }
        }

        let contested = store.circleRanked().filter(\.isSplitDecision).sorted { $0.scoreSpread > $1.scoreSpread }
        var firstScoreByCategory: [DiningCategory: LocationScore] = [:]
        for score in store.ranked() where firstScoreByCategory[score.location.category] == nil {
            firstScoreByCategory[score.location.category] = score
        }
        let leaders = DiningCategory.allCases.compactMap { category in
            firstScoreByCategory[category].map { StatsCategoryLeader(category: category, score: $0) }
        }

        return StatsSnapshot(
            visitCount: visits.count,
            locationCount: locations.count,
            dishCount: locations.reduce(0) { $0 + $1.dishArray.count },
            cityCount: statsCitySummaries(locations).count,
            reactionCounts: reactionCounts,
            ratingCount: ratingCount,
            contested: contested,
            categoryLeaders: leaders,
            returnVisitCount: locations.reduce(0) { $0 + max(0, $1.visitArray.count - 1) },
            memoryCount: memoryCount
        )
    }

    private var isShared: Bool { store.circleMembers.count > 1 }

    private func open(_ destination: StatsDrilldown) {
        Haptics.selection()
        router.morePath.append(.statsDetail(destination))
    }

    private func disagreementDescription(
        lowest: PersonLocationScore?,
        highest: PersonLocationScore?,
        spread: Double
    ) -> String {
        let lowName = lowest.flatMap { store.person(id: $0.personID)?.name } ?? "Two members"
        let highName = highest.flatMap { store.person(id: $0.personID)?.name } ?? "two members"
        return "\(lowName) and \(highName) differ by \(spread.formatted(.number.precision(.fractionLength(1)))) points"
    }
}

@MainActor
struct StatsDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    let drilldown: StatsDrilldown

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                detailContent
            }
            .padding(BBTheme.Spacing.page)
            .padding(.bottom, 32)
            .readablePageWidth()
        }
        .editorialPage()
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var detailContent: some View {
        switch drilldown {
        case .outings:
            outingsDetail
        case .restaurants:
            restaurantsDetail
        case .dishes:
            dishesDetail
        case .cities:
            citiesDetail
        case .city(let name):
            cityDetail(name)
        case .reaction(let rawValue):
            reactionDetail(rawValue)
        case .disagreements:
            disagreementsDetail
        case .categories:
            categoriesDetail
        case .category(let rawValue):
            categoryDetail(rawValue)
        case .repeatOutings:
            repeatOutingsDetail
        case .memories:
            memoriesDetail
        }
    }

    private var outingsDetail: some View {
        let visits = sortedVisits(store.visits)
        return Group {
            detailHero(visits.count, noun: visits.count == 1 ? "outing" : "outings", symbol: "calendar", description: "Every occasion in your dining history, newest first.")
            visitList(visits, emptyTitle: "No outings yet", emptyMessage: "Your dining history will appear here after you log an outing.")
        }
    }

    private var restaurantsDetail: some View {
        let locations = sortedLocations(store.locations)
        return Group {
            detailHero(locations.count, noun: locations.count == 1 ? "restaurant" : "restaurants", symbol: "fork.knife", description: "Every restaurant in your log, ordered by how often you have visited.")
            locationList(locations) { location in
                let city = normalizedCity(location.city)
                return [city, countLabel(location.visitArray.count, singular: "outing")].compactMap { $0 }.joined(separator: " · ")
            }
        }
    }

    private var dishesDetail: some View {
        let dishes = store.locations.flatMap { location in
            location.dishArray.map { StatsDishSummary(dish: $0, location: location) }
        }.sorted {
            let order = $0.dish.name.localizedCaseInsensitiveCompare($1.dish.name)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
        return Group {
            detailHero(dishes.count, noun: dishes.count == 1 ? "dish" : "dishes", symbol: "takeoutbag.and.cup.and.straw", description: "Every named dish, with its restaurant and number of recorded tastings.")
            if dishes.isEmpty {
                emptyDetail("No dishes yet", message: "Dishes show up here when you add them to an outing.", symbol: "takeoutbag.and.cup.and.straw")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(dishes.enumerated()), id: \.element.id) { index, summary in
                        NavigationLink(value: AppRoute.location(summary.location.id, rankingScope: rankingScope)) {
                            HStack(spacing: 12) {
                                IconTile(symbol: summary.dish.role.symbol)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(summary.dish.name).font(.headline)
                                    Text("\(summary.location.name) · \(countLabel(summary.dish.entryArray.count, singular: "entry"))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 64)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < dishes.count - 1 { Divider() }
                    }
                }
                .editorialCard(padding: 12)
            }
        }
    }

    private var citiesDetail: some View {
        let cities = statsCitySummaries(store.locations)
        return Group {
            detailHero(cities.count, noun: cities.count == 1 ? "city" : "cities", symbol: "building.2", description: "Cities are ordered by restaurant count, then by name.")
            if cities.isEmpty {
                emptyDetail("No cities yet", message: "Add a city to a restaurant to build this breakdown.", symbol: "building.2")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    EditorialSectionHeader("Your cities", eyebrow: "Most explored first")
                    VStack(spacing: 0) {
                        ForEach(Array(cities.enumerated()), id: \.element.id) { index, city in
                            Button { open(.city(city.name)) } label: {
                                HStack(spacing: 13) {
                                    ZStack {
                                        Circle().fill(BBTheme.oxblood.opacity(0.09))
                                        Text("\(index + 1)").font(BBTheme.score(18)).foregroundStyle(BBTheme.oxblood)
                                    }
                                    .frame(width: 42, height: 42)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(city.name).font(.headline)
                                        Text("\(countLabel(city.locations.count, singular: "restaurant")) · \(countLabel(city.visitCount, singular: "outing"))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text("\(city.locations.count)").font(BBTheme.score(24)).foregroundStyle(BBTheme.oxblood)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                .frame(minHeight: 64)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(city.name), \(countLabel(city.locations.count, singular: "restaurant")), \(countLabel(city.visitCount, singular: "outing"))")
                            .accessibilityHint("Shows restaurants in \(city.name)")
                            if index < cities.count - 1 { Divider() }
                        }
                    }
                    .editorialCard(padding: 12)
                }
            }
        }
    }

    @ViewBuilder private func cityDetail(_ name: String) -> some View {
        let city = statsCitySummaries(store.locations).first { $0.id == cityKey(name) }
        if let city {
            detailHero(city.locations.count, noun: city.locations.count == 1 ? "restaurant" : "restaurants", symbol: "mappin.and.ellipse", description: "\(countLabel(city.visitCount, singular: "outing")) and \(countLabel(city.dishCount, singular: "dish")) logged in \(city.name).")
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Restaurants in \(city.name)")
                locationList(sortedLocations(city.locations)) { location in
                    "\(location.category.shortTitle) · \(countLabel(location.visitArray.count, singular: "outing"))"
                }
            }
        } else {
            emptyDetail("City not found", message: "This city may have been renamed since you opened Statistics.", symbol: "mappin.slash")
        }
    }

    @ViewBuilder private func reactionDetail(_ rawValue: String) -> some View {
        let reaction = Reaction(rawValue: rawValue)
        let visits = reaction.map { target in
            sortedVisits(store.visits.filter { visit in
                guard let personID = store.currentPerson?.id else { return false }
                return visit.rating(for: personID)?.reaction == target
            })
        } ?? []
        if let reaction {
            detailHero(visits.count, noun: visits.count == 1 ? "outing" : "outings", symbol: reaction.symbol, description: "Outings where your reaction was “\(reaction.title).”")
            visitList(visits, emptyTitle: "No \(reaction.title.lowercased()) outings", emptyMessage: "Choose this reaction on an outing and it will appear here.")
        }
    }

    private var disagreementsDetail: some View {
        let items = store.circleRanked().filter(\.isSplitDecision).sorted { $0.scoreSpread > $1.scoreSpread }
        return Group {
            detailHero(items.count, noun: items.count == 1 ? "split decision" : "split decisions", symbol: "arrow.left.and.right", description: "Restaurants where circle scores are at least 15 points apart, widest gap first.")
            if items.isEmpty {
                emptyDetail("No split decisions", message: "When circle members strongly disagree, those restaurants will appear here.", symbol: "person.2")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let ordered = item.memberScores.sorted { $0.score.score < $1.score.score }
                        NavigationLink(value: AppRoute.location(item.id, rankingScope: .circle)) {
                            HStack(spacing: 12) {
                                IconTile(symbol: "arrow.left.and.right", emphasized: true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.location.name).font(.headline)
                                    Text("\(item.scoreSpread.formatted(.number.precision(.fractionLength(1))))-point spread")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text("\(ordered.first.map { "\($0.score.listScore)" } ?? "—")–\(ordered.last.map { "\($0.score.listScore)" } ?? "—")")
                                    .font(BBTheme.score(20)).foregroundStyle(BBTheme.oxblood)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 64)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < items.count - 1 { Divider() }
                    }
                }
                .editorialCard(padding: 12)
            }
        }
    }

    private var categoriesDetail: some View {
        let categories = statsCategorySummaries(store.locations)
        return Group {
            detailHero(categories.count, noun: categories.count == 1 ? "category" : "categories", symbol: "square.grid.2x2", description: "See how your restaurant log is distributed across dining styles.")
            if categories.isEmpty {
                emptyDetail("No categories yet", message: "Restaurant categories will appear after you start your log.", symbol: "square.grid.2x2")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, summary in
                        Button { open(.category(summary.category.rawValue)) } label: {
                            HStack(spacing: 12) {
                                IconTile(symbol: summary.category.symbol)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(summary.category.shortTitle).font(.headline)
                                    Text("\(countLabel(summary.locations.count, singular: "restaurant")) · \(countLabel(summary.visitCount, singular: "outing"))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text("\(summary.locations.count)").font(BBTheme.score(24)).foregroundStyle(BBTheme.oxblood)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 64)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < categories.count - 1 { Divider() }
                    }
                }
                .editorialCard(padding: 12)
            }
        }
    }

    @ViewBuilder private func categoryDetail(_ rawValue: String) -> some View {
        if let category = DiningCategory(rawValue: rawValue) {
            let locations = sortedLocations(store.locations.filter { $0.category == category })
            let outings = locations.reduce(0) { $0 + $1.visitArray.count }
            detailHero(locations.count, noun: locations.count == 1 ? "restaurant" : "restaurants", symbol: category.symbol, description: "\(countLabel(outings, singular: "outing")) across \(category.shortTitle.lowercased()).")
            locationList(locations) { location in
                [normalizedCity(location.city), countLabel(location.visitArray.count, singular: "outing")].compactMap { $0 }.joined(separator: " · ")
            }
        } else {
            emptyDetail("Category not found", message: "This category is no longer available.", symbol: "questionmark.square")
        }
    }

    private var repeatOutingsDetail: some View {
        let locations = store.locations.filter { $0.visitArray.count > 1 }.sorted {
            if $0.visitArray.count != $1.visitArray.count { return $0.visitArray.count > $1.visitArray.count }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let repeatCount = locations.reduce(0) { $0 + $1.visitArray.count - 1 }
        return Group {
            detailHero(repeatCount, noun: repeatCount == 1 ? "repeat outing" : "repeat outings", symbol: "repeat", description: "Every outing after your first visit to the same restaurant.")
            if locations.isEmpty {
                emptyDetail("No return visits yet", message: "Restaurants you visit more than once will appear here.", symbol: "repeat")
            } else {
                locationList(locations) { location in
                    "\(countLabel(location.visitArray.count, singular: "outing")) · \(countLabel(location.visitArray.count - 1, singular: "repeat"))"
                }
            }
        }
    }

    private var memoriesDetail: some View {
        let visits = sortedVisits(store.visits.filter { visit in
            guard let personID = store.currentPerson?.id else { return false }
            return store.memory(for: visit, personID: personID)?.isEmpty == false
        })
        return Group {
            detailHero(visits.count, noun: visits.count == 1 ? "memory" : "memories", symbol: "quote.opening", description: "The notes you saved with your outings, newest first.")
            if visits.isEmpty {
                emptyDetail("No memories yet", message: "Add a memory to an outing and it will appear here.", symbol: "quote.opening")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visits.enumerated()), id: \.element.objectID) { index, visit in
                        NavigationLink(value: AppRoute.visit(visit.id)) {
                            VStack(alignment: .leading, spacing: 9) {
                                VisitRow(visit: visit)
                                if let personID = store.currentPerson?.id, let memory = store.memory(for: visit, personID: personID) {
                                    Text("“\(memory)”")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                        .padding(.leading, 69)
                                }
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < visits.count - 1 { Divider() }
                    }
                }
                .editorialCard(padding: 12)
            }
        }
    }

    private func detailHero(_ value: Int, noun: String, symbol: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Eyebrow("Statistics", color: BBTheme.cream.opacity(0.76))
                Text("\(value)").font(BBTheme.score(52)).foregroundStyle(BBTheme.cream)
                Text(noun.uppercased()).font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(BBTheme.cream.opacity(0.78))
                Text(description).font(.callout).foregroundStyle(BBTheme.cream.opacity(0.82)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(BBTheme.cream)
                .frame(width: 54, height: 54)
                .background(BBTheme.cream.opacity(0.12), in: Circle())
        }
        .padding(20)
        .background(
            LinearGradient(colors: [BBTheme.oxbloodFill, BBTheme.oxbloodFill.opacity(0.84)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous)
                .stroke(BBTheme.cream.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: BBTheme.oxbloodFill.opacity(0.16), radius: 16, y: 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func visitList(_ visits: [VisitEntity], emptyTitle: String, emptyMessage: String) -> some View {
        if visits.isEmpty {
            emptyDetail(emptyTitle, message: emptyMessage, symbol: "calendar")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(visits.enumerated()), id: \.element.objectID) { index, visit in
                    NavigationLink(value: AppRoute.visit(visit.id)) {
                        VisitRow(visit: visit).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    if index < visits.count - 1 { Divider() }
                }
            }
            .editorialCard(padding: 12)
        }
    }

    @ViewBuilder private func locationList(
        _ locations: [RestaurantLocation],
        detail: @escaping (RestaurantLocation) -> String
    ) -> some View {
        if locations.isEmpty {
            emptyDetail("No restaurants yet", message: "Restaurants will appear here after you add them to your log.", symbol: "fork.knife")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(locations.enumerated()), id: \.element.objectID) { index, location in
                    NavigationLink(value: AppRoute.location(location.id, rankingScope: rankingScope)) {
                        HStack(spacing: 12) {
                            IconTile(symbol: location.category.symbol)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(location.name).font(.headline)
                                Text(detail(location)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 64)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < locations.count - 1 { Divider() }
                }
            }
            .editorialCard(padding: 12)
        }
    }

    private func emptyDetail(_ title: String, message: String, symbol: String) -> some View {
        EmptyLogView(title: title, message: message, symbol: symbol)
            .editorialCard()
    }

    private var rankingScope: RankingScope? {
        store.currentPerson.map { .person($0.id) }
    }

    private func open(_ destination: StatsDrilldown) {
        Haptics.selection()
        router.morePath.append(.statsDetail(destination))
    }

    private func sortedVisits(_ visits: [VisitEntity]) -> [VisitEntity] {
        visits.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func sortedLocations(_ locations: [RestaurantLocation]) -> [RestaurantLocation] {
        locations.sorted {
            if $0.visitArray.count != $1.visitArray.count { return $0.visitArray.count > $1.visitArray.count }
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private var navigationTitle: String {
        switch drilldown {
        case .outings: "Outings"
        case .restaurants: "Restaurants"
        case .dishes: "Dishes"
        case .cities: "Cities"
        case .city(let name): name
        case .reaction(let rawValue): Reaction(rawValue: rawValue)?.title ?? "Reactions"
        case .disagreements: "Split Decisions"
        case .categories: "Categories"
        case .category(let rawValue): DiningCategory(rawValue: rawValue)?.shortTitle ?? "Category"
        case .repeatOutings: "Repeat Outings"
        case .memories: "Memories"
        }
    }
}

private func normalizedCity(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func cityKey(_ city: String) -> String {
    city.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
}

private func statsCitySummaries(_ locations: [RestaurantLocation]) -> [StatsCitySummary] {
    let knownLocations = locations.compactMap { location -> (String, String, RestaurantLocation)? in
        guard let city = normalizedCity(location.city) else { return nil }
        return (cityKey(city), city, location)
    }
    let grouped = Dictionary(grouping: knownLocations, by: \.0)
    return grouped.map { key, values in
        let names = Dictionary(grouping: values.map(\.1), by: { $0 }).map { name, occurrences in (name, occurrences.count) }
        let displayName = names.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending
        }.first?.0 ?? values[0].1
        return StatsCitySummary(id: key, name: displayName, locations: values.map(\.2))
    }.sorted {
        if $0.locations.count != $1.locations.count { return $0.locations.count > $1.locations.count }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}

private func statsCategorySummaries(_ locations: [RestaurantLocation]) -> [StatsCategorySummary] {
    DiningCategory.allCases.compactMap { category in
        let matching = locations.filter { $0.category == category }
        return matching.isEmpty ? nil : StatsCategorySummary(category: category, locations: matching)
    }.sorted {
        if $0.locations.count != $1.locations.count { return $0.locations.count > $1.locations.count }
        return $0.category.shortTitle.localizedCaseInsensitiveCompare($1.category.shortTitle) == .orderedAscending
    }
}

private func countLabel(_ count: Int, singular: String) -> String {
    "\(count) \(count == 1 ? singular : singular + "s")"
}
