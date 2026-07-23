import SwiftUI

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

@MainActor
struct StatsView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        let snapshot = statsSnapshot
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Eyebrow("Your dining history")
                    Text("The shape of your log").font(BBTheme.display(37))
                    Text("Patterns, favorites, and disagreements across every visit you’ve kept.")
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
            metric("\(snapshot.visitCount)", "meals recorded")
            metric("\(snapshot.locationCount)", "establishments")
            metric("\(snapshot.dishCount)", "dishes remembered")
            metric("\(snapshot.cityCount)", "cities")
        }
    }
    private func metric(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(BBTheme.score(43)).foregroundStyle(BBTheme.oxblood)
            Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .editorialCard()
        .accessibilityElement(children: .combine)
    }

    private func reactionDistribution(_ snapshot: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            EditorialSectionHeader("The verdicts", eyebrow: "Personal reactions")
            ForEach(Reaction.allCases) { reaction in
                let count = snapshot.reactionCounts[reaction] ?? 0
                VStack(spacing: 7) {
                    HStack {
                        Label(reaction.rawValue, systemImage: reaction.symbol)
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(count), total: Double(max(1, snapshot.ratingCount)))
                        .tint(BBTheme.oxblood)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(reaction.rawValue), \(count) of \(snapshot.ratingCount) ratings")
            }
        }.editorialCard()
    }

    @ViewBuilder private func contested(_ split: [CircleLocationScore]) -> some View {
        if !split.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Most contested", eyebrow: "Split decisions")
                ForEach(split.prefix(5)) { item in
                    let ordered = item.memberScores.sorted { $0.score.score < $1.score.score }
                    let lowest = ordered.first
                    let highest = ordered.last
                    Button { router.morePath.append(.location(item.id)) } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: "arrow.left.and.right", emphasized: true)
                            VStack(alignment: .leading) {
                                Text(item.location.name).font(.headline)
                                Text(disagreementDescription(lowest: lowest, highest: highest, spread: item.scoreSpread))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Text("\(lowest?.score.displayScore ?? "—")–\(highest?.score.displayScore ?? "—")")
                                .font(BBTheme.score(19)).foregroundStyle(BBTheme.oxblood)
                        }
                        .frame(minHeight: 62)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if item.id != split.prefix(5).last?.id { Divider() }
                }
            }.editorialCard()
        }
    }

    @ViewBuilder private func categoryLeaders(_ leaders: [StatsCategoryLeader]) -> some View {
        if !leaders.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Category leaders", eyebrow: "Top rated")
                ForEach(leaders) { leader in
                    Button { router.morePath.append(.location(leader.score.id)) } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: leader.category.symbol)
                            VStack(alignment: .leading) {
                                Text(leader.category.shortTitle).font(.caption).foregroundStyle(.secondary)
                                Text(leader.score.location.name).font(.headline)
                            }
                            Spacer(minLength: 8)
                            Text(leader.score.displayScore).font(BBTheme.score(22))
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 62)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }.editorialCard()
        }
    }

    private func memoryStats(_ snapshot: StatsSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                memoryMetric("\(snapshot.returnVisitCount)", "RETURN VISITS")
                Divider()
                memoryMetric("\(snapshot.memoryCount)", "MEMORIES KEPT")
            }
            VStack(spacing: 12) {
                memoryMetric("\(snapshot.returnVisitCount)", "RETURN VISITS")
                Divider()
                memoryMetric("\(snapshot.memoryCount)", "MEMORIES KEPT")
            }
        }
        .editorialCard()
    }

    private func memoryMetric(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(BBTheme.score(35))
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var statsSnapshot: StatsSnapshot {
        let visits = store.visits
        let locations = store.locations
        let personID = store.currentPerson?.id
        var reactionCounts: [Reaction: Int] = [:]
        var ratingCount = 0
        var memoryCount = 0
        for visit in visits {
            if visit.memory?.isEmpty == false { memoryCount += 1 }
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
            dishCount: locations.reduce(0) { $0 + ($1.dishes?.count ?? 0) },
            cityCount: Set(locations.compactMap(\.city)).count,
            reactionCounts: reactionCounts,
            ratingCount: ratingCount,
            contested: contested,
            categoryLeaders: leaders,
            returnVisitCount: locations.reduce(0) { $0 + max(0, ($1.visits?.count ?? 0) - 1) },
            memoryCount: memoryCount
        )
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
