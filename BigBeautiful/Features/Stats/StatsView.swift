import SwiftUI

@MainActor
struct StatsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) { Eyebrow("The state of the table"); Text("Statistics, with dignity.").font(BBTheme.display(37)); Text("Patterns from your record. No engagement metrics were harmed.").foregroundStyle(.secondary) }
                metricGrid
                reactionDistribution
                contested
                categoryLeaders
                memoryStats
            }.padding(18).padding(.bottom, 26).readablePageWidth()
        }.editorialPage().navigationTitle("Statistics").navigationBarTitleDisplayMode(.inline)
    }

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
            metric("\(store.visits.count)", "meals recorded")
            metric("\(store.locations.count)", "establishments")
            metric("\(store.locations.flatMap(\.dishArray).count)", "dishes remembered")
            metric("\(Set(store.locations.compactMap(\.city)).count)", "cities")
        }
    }
    private func metric(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(value).font(BBTheme.score(43)).foregroundStyle(BBTheme.oxblood); Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: 88, alignment: .leading).ledgerCard()
    }

    private var reactionDistribution: some View {
        let ratings = store.visits.compactMap { visit in store.currentPerson.flatMap { visit.rating(for: $0.id) } }
        return VStack(alignment: .leading, spacing: 13) {
            EditorialSectionHeader("The verdicts", eyebrow: "Personal reactions")
            ForEach(Reaction.allCases) { reaction in
                let count = ratings.filter { $0.reaction == reaction }.count
                HStack { Label(reaction.rawValue, systemImage: reaction.symbol).frame(width: 145, alignment: .leading); GeometryReader { proxy in Rectangle().fill(BBTheme.ink.opacity(0.06)).overlay(alignment: .leading) { Rectangle().fill(BBTheme.oxblood).frame(width: proxy.size.width * CGFloat(count) / CGFloat(max(1, ratings.count))) } }.frame(height: 6); Text("\(count)").font(.caption.monospacedDigit()).frame(width: 24, alignment: .trailing) }
            }
        }.ledgerCard()
    }

    @ViewBuilder private var contested: some View {
        let split = store.coupleRanked().filter(\.isSplitDecision).sorted { abs($0.myScore.score - $0.partnerScore.score) > abs($1.myScore.score - $1.partnerScore.score) }
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

    private var categoryLeaders: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeader("Category leaders", eyebrow: "Seven small crowns")
            ForEach(DiningCategory.allCases) { category in
                let leader = store.ranked().first { $0.location.category == category }
                HStack { Image(systemName: category.symbol).foregroundStyle(BBTheme.oxblood).frame(width: 28); VStack(alignment: .leading) { Text(category.shortTitle).font(.caption).foregroundStyle(.secondary); Text(leader?.location.name ?? "No entrant").font(.headline) }; Spacer(); if let leader { Text(leader.displayScore).font(BBTheme.score(22)) } }
            }
        }.ledgerCard()
    }

    private var memoryStats: some View {
        let returnVisits = store.locations.reduce(0) { $0 + max(0, $1.visitArray.count - 1) }
        let memories = store.visits.filter { $0.memory?.isEmpty == false }.count
        return HStack(spacing: 12) {
            VStack(alignment: .leading) { Text("\(returnVisits)").font(BBTheme.score(35)); Text("RETURN VISITS").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading) { Text("\(memories)").font(BBTheme.score(35)); Text("MEMORIES KEPT").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
        }.ledgerCard()
    }
}
