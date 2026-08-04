import Foundation

struct RankingHistoryScore: Identifiable, Equatable {
    let locationID: UUID
    let locationName: String
    let category: DiningCategory
    let score: Double
    let overallRank: Int
    let categoryRank: Int

    var id: UUID { locationID }
}

struct RankingHistorySnapshot: Identifiable, Equatable {
    let date: Date
    let scores: [RankingHistoryScore]

    var id: Date { date }
}

/// Reconstructs the ranking at the moments when ranking evidence became
/// available. The stored records remain the source of truth; these snapshots
/// are derived only for the visualization and should never be synced.
struct RankingHistoryBuilder {
    private let rankingEngine: RankingEngine

    init(rankingEngine: RankingEngine = RankingEngine()) {
        self.rankingEngine = rankingEngine
    }

    func personSnapshots(
        locations: [RestaurantLocation],
        comparisons: [ComparisonEntity],
        personID: UUID,
        through endDate: Date = .now
    ) -> [RankingHistorySnapshot] {
        snapshots(
            locations: locations,
            comparisons: comparisons,
            personIDs: [personID],
            through: endDate
        ) { date in
            rankingEngine.scores(
                locations: locations,
                comparisons: comparisons,
                personID: personID,
                asOf: date,
                evidenceAvailableThrough: date
            ).map(Self.score)
        }
    }

    func circleSnapshots(
        locations: [RestaurantLocation],
        comparisons: [ComparisonEntity],
        personIDs: [UUID],
        through endDate: Date = .now
    ) -> [RankingHistorySnapshot] {
        snapshots(
            locations: locations,
            comparisons: comparisons,
            personIDs: personIDs,
            through: endDate
        ) { date in
            rankingEngine.circleScores(
                locations: locations,
                comparisons: comparisons,
                personIDs: personIDs,
                asOf: date,
                evidenceAvailableThrough: date
            ).map { value in
                RankingHistoryScore(
                    locationID: value.id,
                    locationName: value.location.name,
                    category: value.location.category,
                    score: value.score,
                    overallRank: value.overallRank,
                    categoryRank: value.categoryRank
                )
            }
        }
    }

    private func snapshots(
        locations: [RestaurantLocation],
        comparisons: [ComparisonEntity],
        personIDs: [UUID],
        through endDate: Date,
        makeScores: (Date) -> [RankingHistoryScore]
    ) -> [RankingHistorySnapshot] {
        guard !personIDs.isEmpty else { return [] }
        let dates = evidenceDates(
            locations: locations,
            comparisons: comparisons,
            personIDs: personIDs,
            through: endDate
        )
        return dates.compactMap { date in
            let scores = makeScores(date)
            guard !scores.isEmpty else { return nil }
            return RankingHistorySnapshot(date: date, scores: scores)
        }
    }

    private func evidenceDates(
        locations: [RestaurantLocation],
        comparisons: [ComparisonEntity],
        personIDs: [UUID],
        through endDate: Date
    ) -> [Date] {
        let personIDSet = Set(personIDs)
        var dates = locations.flatMap { location in
            location.visitArray.flatMap { visit in
                personIDs.compactMap { personID in
                    visit.rating(for: personID)?.createdAt
                }
            }
        }
        dates.append(contentsOf: comparisons.compactMap { comparison in
            guard personIDSet.contains(comparison.personID), comparison.date <= endDate else { return nil }
            return comparison.date
        })
        dates = dates.filter { $0 <= endDate }

        guard let latest = dates.max() else { return [] }
        if latest < endDate { dates.append(endDate) }
        return Array(Set(dates)).sorted()
    }

    private static func score(_ value: LocationScore) -> RankingHistoryScore {
        RankingHistoryScore(
            locationID: value.id,
            locationName: value.location.name,
            category: value.location.category,
            score: value.score,
            overallRank: value.overallRank,
            categoryRank: value.categoryRank
        )
    }
}
