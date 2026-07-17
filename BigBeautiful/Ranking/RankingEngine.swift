import Foundation

struct LocationScore: Identifiable {
    let location: RestaurantLocation
    let score: Double
    let certainty: Double
    let ratedVisitCount: Int
    let comparisonCount: Int
    var overallRank: Int = 0
    var categoryRank: Int = 0

    var id: UUID { location.id }
    var isProvisional: Bool { ratedVisitCount < 2 && comparisonCount < 4 }
    var displayScore: String { score.formatted(.number.precision(.fractionLength(1))) }
}

struct CoupleLocationScore: Identifiable {
    let location: RestaurantLocation
    let myScore: LocationScore
    let partnerScore: LocationScore
    var overallRank: Int = 0
    var categoryRank: Int = 0

    var id: UUID { location.id }
    var score: Double { (myScore.score + partnerScore.score) / 2 }
    var displayScore: String { score.formatted(.number.precision(.fractionLength(1))) }
    var isSplitDecision: Bool { abs(myScore.score - partnerScore.score) >= 15 }
    var isProvisional: Bool { myScore.isProvisional || partnerScore.isProvisional }
}

struct RankingEngine {
    static let detailAdjustmentLimit = 7.0
    static let establishedVisitMovementLimit = 3.5

    func scores(
        locations: [RestaurantLocation],
        comparisons: [ComparisonEntity],
        personID: UUID,
        asOf date: Date = .now
    ) -> [LocationScore] {
        let active = locations.filter { !$0.isClosed }
        let personComparisons = comparisons.filter { $0.personID == personID }
        let anchorsByLocation = Dictionary(grouping: personComparisons.filter(\.isAnchor), by: \.locationAID)
        let pairComparisons = personComparisons.filter { !$0.isAnchor && $0.outcome != .skipped }
        var states: [UUID: State] = [:]

        for location in active {
            let ratings = location.visitArray.reversed().compactMap { visit -> VisitEvidence? in
                guard let rating = visit.rating(for: personID) else { return nil }
                return VisitEvidence(visit: visit, rating: rating, value: visitValue(visit: visit, rating: rating))
            }
            let anchors = anchorsByLocation[location.id] ?? []
            guard !ratings.isEmpty || !anchors.isEmpty else { continue }

            var base = weightedMean(ratings: ratings, asOf: date)
            if ratings.count >= 5 {
                let historical = weightedMean(ratings: Array(ratings.dropLast()), asOf: date)
                let withLatest = weightedMean(ratings: ratings, asOf: date)
                let movement = (withLatest.mean - historical.mean).clamped(to: -Self.establishedVisitMovementLimit...Self.establishedVisitMovementLimit)
                base.mean = historical.mean + movement
                base.weight = withLatest.weight
            }

            if !anchors.isEmpty {
                let anchorMean = anchors.map(\.anchorValue).reduce(0, +) / Double(anchors.count)
                let anchorWeight = min(2.5, Double(anchors.count) * 0.8)
                base.mean = ((base.mean * base.weight) + (anchorMean * anchorWeight)) / max(0.01, base.weight + anchorWeight)
                base.weight += anchorWeight
            }

            let dishOutlook = predictiveDishAdjustment(location: location, personID: personID)
            states[location.id] = State(
                location: location,
                score: (base.mean + dishOutlook).clamped(to: 0...100),
                certainty: base.weight,
                visits: ratings.count,
                comparisons: 0
            )
        }

        for _ in 0..<6 {
            for comparison in pairComparisons {
                guard var a = states[comparison.locationAID], var b = states[comparison.locationBID] else { continue }
                let expectedA = 1 / (1 + pow(10, (b.score - a.score) / 24))
                let actualA: Double = switch comparison.outcome {
                case .a: 1
                case .b: 0
                case .tie: 0.5
                case .skipped: expectedA
                }
                let residual = actualA - expectedA
                let baseStep = comparison.outcome == .tie ? 2.4 : 4.2
                let aStep = baseStep / (1 + a.certainty / 5)
                let bStep = baseStep / (1 + b.certainty / 5)
                a.score = (a.score + residual * aStep).clamped(to: 0...100)
                b.score = (b.score - residual * bStep).clamped(to: 0...100)
                states[a.location.id] = a
                states[b.location.id] = b
            }
        }

        for comparison in pairComparisons {
            states[comparison.locationAID]?.comparisons += 1
            states[comparison.locationBID]?.comparisons += 1
            states[comparison.locationAID]?.certainty += comparison.outcome == .tie ? 0.45 : 0.65
            states[comparison.locationBID]?.certainty += comparison.outcome == .tie ? 0.45 : 0.65
        }

        var result = states.values.map {
            LocationScore(
                location: $0.location,
                score: $0.score,
                certainty: $0.certainty,
                ratedVisitCount: $0.visits,
                comparisonCount: $0.comparisons
            )
        }.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.location.name < rhs.location.name }
            return lhs.score > rhs.score
        }

        var categoryRanks: [DiningCategory: Int] = [:]
        for index in result.indices {
            result[index].overallRank = index + 1
            let category = result[index].location.category
            categoryRanks[category, default: 0] += 1
            result[index].categoryRank = categoryRanks[category, default: 0]
        }
        return result
    }

    func coupleScores(
        locations: [RestaurantLocation],
        comparisons: [ComparisonEntity],
        myID: UUID,
        partnerID: UUID,
        asOf date: Date = .now
    ) -> [CoupleLocationScore] {
        let mine = Dictionary(uniqueKeysWithValues: scores(locations: locations, comparisons: comparisons, personID: myID, asOf: date).map { ($0.id, $0) })
        let theirs = Dictionary(uniqueKeysWithValues: scores(locations: locations, comparisons: comparisons, personID: partnerID, asOf: date).map { ($0.id, $0) })
        var result = locations.compactMap { location -> CoupleLocationScore? in
            guard let myScore = mine[location.id], let partnerScore = theirs[location.id] else { return nil }
            return CoupleLocationScore(location: location, myScore: myScore, partnerScore: partnerScore)
        }.sorted { $0.score > $1.score }
        var categoryRanks: [DiningCategory: Int] = [:]
        for index in result.indices {
            result[index].overallRank = index + 1
            let category = result[index].location.category
            categoryRanks[category, default: 0] += 1
            result[index].categoryRank = categoryRanks[category, default: 0]
        }
        return result
    }

    func visitValue(visit: VisitEntity, rating: RatingEntity) -> Double {
        (rating.reaction.anchor + detailAdjustment(visit: visit, rating: rating)).clamped(to: 0...100)
    }

    func detailAdjustment(visit: VisitEntity, rating: RatingEntity) -> Double {
        var adjustment = 0.0
        if let value = rating.value { adjustment += signal(value) * 2.0 }
        if let service = rating.service { adjustment += signal(service) * 0.8 }
        if let atmosphere = rating.atmosphere { adjustment += signal(atmosphere) * 0.7 }
        if rating.hasWouldOrderAgain { adjustment += rating.wouldOrderAgain ? 1.2 : -1.2 }

        let dishEntries = visit.dishEntryArray.filter { $0.personID == rating.personID }
        if !dishEntries.isEmpty {
            let weighted = dishEntries.reduce(into: (total: 0.0, weight: 0.0)) { partial, entry in
                let weight = entry.dish?.role.weight ?? 0.6
                partial.total += signal(entry.reaction) * weight
                partial.weight += weight
            }
            adjustment += (weighted.total / max(0.01, weighted.weight)) * 3.3
        }
        return adjustment.clamped(to: -Self.detailAdjustmentLimit...Self.detailAdjustmentLimit)
    }

    func recencyWeight(visitDate: Date, asOf date: Date) -> Double {
        let days = max(0, date.timeIntervalSince(visitDate) / 86_400)
        let effectiveDays = max(0, days - 30)
        return pow(0.5, effectiveDays / 1_065)
    }

    private func weightedMean(ratings: [VisitEvidence], asOf date: Date) -> (mean: Double, weight: Double) {
        guard !ratings.isEmpty else { return (60, 0.08) }
        var total = 60 * 0.08
        var weight = 0.08
        for evidence in ratings {
            let memoryWeight = evidence.rating.hazyMemory ? 0.35 : 1.0
            let evidenceWeight = recencyWeight(visitDate: evidence.visit.date, asOf: date) * memoryWeight
            total += evidence.value * evidenceWeight
            weight += evidenceWeight
        }
        return (total / weight, weight)
    }

    private func predictiveDishAdjustment(location: RestaurantLocation, personID: UUID) -> Double {
        let entries = location.dishArray.flatMap(\.entryArray).filter { $0.personID == personID }
        guard !entries.isEmpty else { return 0 }
        let reorderable = entries.filter(\.wouldOrderAgain)
        let pool = reorderable.isEmpty ? entries : reorderable
        let average = pool.reduce(into: (total: 0.0, weight: 0.0)) { partial, entry in
            let weight = entry.dish?.role.weight ?? 0.6
            partial.total += signal(entry.reaction) * weight
            partial.weight += weight
        }
        return ((average.total / max(0.01, average.weight)) * 2.6).clamped(to: -3...3)
    }

    private func signal(_ reaction: Reaction) -> Double {
        ((reaction.anchor - 57.5) / 27.5).clamped(to: -1...1)
    }

    private struct VisitEvidence {
        let visit: VisitEntity
        let rating: RatingEntity
        let value: Double
    }

    private struct State {
        let location: RestaurantLocation
        var score: Double
        var certainty: Double
        let visits: Int
        var comparisons: Int
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
