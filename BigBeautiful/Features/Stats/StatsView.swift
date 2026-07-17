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
    let contested: [CoupleLocationScore]
    let categoryLeaders: [StatsCategoryLeader]
    let returnVisitCount: Int
    let memoryCount: Int
}

@MainActor
struct StatsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let snapshot = statsSnapshot
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) { Eyebrow("Your dining history"); Text("Statistics").font(BBTheme.display(37)); Text("A summary of the places and meals you’ve logged.").foregroundStyle(.secondary) }
                metricGrid(snapshot)
                reactionDistribution(snapshot)
                contested(snapshot.contested)
                categoryLeaders(snapshot.categoryLeaders)
                memoryStats(snapshot)
            }.padding(18).padding(.bottom, 26).readablePageWidth()
        }.editorialPage().navigationTitle("Statistics").navigationBarTitleDisplayMode(.inline)
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
        VStack(alignment: .leading, spacing: 5) { Text(value).font(BBTheme.score(43)).foregroundStyle(BBTheme.oxblood); Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: 88, alignment: .leading).ledgerCard()
    }

    private func reactionDistribution(_ snapshot: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            EditorialSectionHeader("The verdicts", eyebrow: "Personal reactions")
            ForEach(Reaction.allCases) { reaction in
                let count = snapshot.reactionCounts[reaction] ?? 0
                HStack { Label(reaction.rawValue, systemImage: reaction.symbol).frame(width: 145, alignment: .leading); GeometryReader { proxy in Rectangle().fill(BBTheme.ink.opacity(0.06)).overlay(alignment: .leading) { Rectangle().fill(BBTheme.oxblood).frame(width: proxy.size.width * CGFloat(count) / CGFloat(max(1, snapshot.ratingCount))) } }.frame(height: 6); Text("\(count)").font(.caption.monospacedDigit()).frame(width: 24, alignment: .trailing) }
            }
        }.ledgerCard()
    }

    @ViewBuilder private func contested(_ split: [CoupleLocationScore]) -> some View {
        if !split.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Most contested", eyebrow: "Split decisions")
                ForEach(split.prefix(5)) { item in
                    HStack { VStack(alignment: .leading) { Text(item.location.name).font(.headline); Text("A \(abs(item.myScore.score - item.partnerScore.score).formatted(.number.precision(.fractionLength(1))))-point disagreement").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("\(item.myScore.displayScore) / \(item.partnerScore.displayScore)").font(BBTheme.score(19)).foregroundStyle(BBTheme.oxblood) }
                    if item.id != split.prefix(5).last?.id { Divider() }
                }
            }.ledgerCard()
        }
    }

    @ViewBuilder private func categoryLeaders(_ leaders: [StatsCategoryLeader]) -> some View {
        if !leaders.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Category leaders", eyebrow: "Top rated")
                ForEach(leaders) { leader in
                    HStack { Image(systemName: leader.category.symbol).foregroundStyle(BBTheme.oxblood).frame(width: 28); VStack(alignment: .leading) { Text(leader.category.shortTitle).font(.caption).foregroundStyle(.secondary); Text(leader.score.location.name).font(.headline) }; Spacer(); Text(leader.score.displayScore).font(BBTheme.score(22)) }
                }
            }.ledgerCard()
        }
    }

    private func memoryStats(_ snapshot: StatsSnapshot) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading) { Text("\(snapshot.returnVisitCount)").font(BBTheme.score(35)); Text("RETURN VISITS").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading) { Text("\(snapshot.memoryCount)").font(BBTheme.score(35)); Text("MEMORIES KEPT").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
        }.ledgerCard()
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

        let contested = store.coupleRanked().filter(\.isSplitDecision).sorted {
            abs($0.myScore.score - $0.partnerScore.score) > abs($1.myScore.score - $1.partnerScore.score)
        }
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
}
