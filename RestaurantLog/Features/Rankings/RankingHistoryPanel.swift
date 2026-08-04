import Charts
import SwiftUI

private enum RankingHistoryScale: CaseIterable, Identifiable {
    case minutes
    case hours
    case day
    case week
    case month
    case year

    var id: Self { self }

    var duration: TimeInterval {
        switch self {
        case .minutes: 15 * 60
        case .hours: 6 * 60 * 60
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        case .month: 31 * 24 * 60 * 60
        case .year: 365 * 24 * 60 * 60
        }
    }

    var title: String {
        switch self {
        case .minutes: "15 minutes"
        case .hours: "6 hours"
        case .day: "1 day"
        case .week: "1 week"
        case .month: "1 month"
        case .year: "1 year"
        }
    }

    var compactTitle: String {
        switch self {
        case .minutes: "15m"
        case .hours: "6h"
        case .day: "1d"
        case .week: "1w"
        case .month: "1mo"
        case .year: "1y"
        }
    }
}

private struct RankingHistoryChartPoint: Identifiable {
    let locationID: UUID
    let name: String
    let date: Date
    let rank: Int
    let isCurrent: Bool

    var id: String { "\(locationID.uuidString)-\(date.timeIntervalSinceReferenceDate)" }
}

private struct RankingHistoryChartData {
    let points: [RankingHistoryChartPoint]
    let seriesKeys: [String]
    let colors: [Color]
    let maxRank: Int
    let xDomain: ClosedRange<Date>
    let latestDate: Date?
}

private struct RankingHistoryInputKey: Hashable {
    let revision: Int
    let scope: RankingScope
    let category: String?
    let locationIDs: [UUID]
}

@MainActor
struct RankingHistoryPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let scope: RankingScope
    let category: DiningCategory?
    let locationIDs: [UUID]

    @State private var snapshots: [RankingHistorySnapshot] = []
    @State private var isPreparing = true
    @State private var selectedIDs: Set<UUID> = []
    @State private var visibleDuration = RankingHistoryScale.month.duration
    @State private var scrollPosition = Date.now
    @State private var pinchStartDuration: TimeInterval?
    @State private var hasChosenInitialScale = false

    private let minimumVisibleDuration = 15 * 60.0
    private let maximumVisibleDuration = 365 * 24 * 60 * 60.0
    private let initialSeriesCount = 6

    var body: some View {
        let data = chartData
        VStack(alignment: .leading, spacing: 15) {
            header(data)

            if isPreparing {
                chartPlaceholder
            } else if data.points.isEmpty {
                EmptyLogView(
                    title: "Not enough ranking history",
                    message: "As you add outings and comparisons, the shape of your rankings will appear here.",
                    symbol: "chart.xyaxis.line"
                )
                .frame(maxWidth: .infinity)
            } else {
                rankingChart(data)
                zoomControls
                restaurantSelector
            }
        }
        .editorialCard(padding: 16)
        .task(id: inputKey) {
            rebuildHistory()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ranking-history-panel")
    }

    private func header(_ data: RankingHistoryChartData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Ranking history")
                    Text("How your rankings moved")
                        .font(BBTheme.display(25))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(BBTheme.oxblood)
                    .frame(width: 42, height: 42)
                    .background(BBTheme.oxblood.opacity(0.09), in: Circle())
            }
            Text("Rank 1 stays at the top. Pinch to zoom, drag through time, or choose a scale from 15 minutes to 1 year.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let latestDate = data.latestDate {
                Text("Current as of \(latestDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(BBTheme.oxblood)
            }
        }
    }

    private var chartPlaceholder: some View {
        RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
            .fill(BBTheme.surfaceMuted.opacity(0.55))
            .frame(height: 242)
            .overlay {
                ProgressView()
                    .tint(BBTheme.oxblood)
            }
            .redacted(reason: .placeholder)
    }

    private func rankingChart(_ data: RankingHistoryChartData) -> some View {
        Chart {
            ForEach(data.points) { point in
                LineMark(
                    x: .value("Recorded", point.date),
                    y: .value("Rank", -Double(point.rank)),
                    series: .value("Restaurant", point.locationID.uuidString)
                )
                .interpolationMethod(.stepEnd)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(by: .value("Restaurant", point.locationID.uuidString))

                PointMark(
                    x: .value("Recorded", point.date),
                    y: .value("Rank", -Double(point.rank))
                )
                .symbolSize(point.isCurrent ? 52 : 22)
                .foregroundStyle(by: .value("Restaurant", point.locationID.uuidString))
            }
        }
        .chartForegroundStyleScale(domain: data.seriesKeys, range: data.colors)
        .chartLegend(.hidden)
        .chartYScale(domain: -Double(data.maxRank + 1)...0)
        .chartXScale(domain: data.xDomain)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleDuration)
        .chartScrollPosition(x: $scrollPosition)
        .chartYAxis {
            AxisMarks(position: .leading, values: yAxisValues(for: data.maxRank)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
                    .foregroundStyle(BBTheme.hairline)
                AxisTick(stroke: StrokeStyle(lineWidth: 0.7))
                    .foregroundStyle(BBTheme.hairline)
                AxisValueLabel {
                    if let rawValue = value.as(Double.self) {
                        Text("#\(abs(Int(rawValue.rounded())))")
                            .font(.caption2.weight(.semibold))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: xAxisLabelCount)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
                    .foregroundStyle(BBTheme.hairline.opacity(0.75))
                AxisTick(stroke: StrokeStyle(lineWidth: 0.7))
                    .foregroundStyle(BBTheme.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(for: date))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .background(BBTheme.surfaceMuted.opacity(0.2))
                .overlay {
                    RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                        .stroke(BBTheme.hairline)
                }
                .clipShape(RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous))
        }
        .frame(height: 250)
        .contentShape(Rectangle())
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    let start = pinchStartDuration ?? visibleDuration
                    if pinchStartDuration == nil { pinchStartDuration = start }
                    setVisibleDuration(start / Double(value), animated: false)
                }
                .onEnded { _ in
                    pinchStartDuration = nil
                }
        )
        .accessibilityLabel("Ranking history chart")
        .accessibilityHint("Ranks improve toward the top. Use the scale controls to zoom from minutes to a year, then drag through time.")
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { stepScale(toward: .larger) } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
            .background(BBTheme.surface, in: RoundedRectangle(cornerRadius: BBTheme.Radius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BBTheme.Radius.small, style: .continuous)
                    .stroke(BBTheme.hairline)
            }
            .disabled(!canZoomOut)
            .opacity(canZoomOut ? 1 : 0.35)
            .accessibilityLabel("Zoom out of ranking history")

            Menu {
                ForEach(RankingHistoryScale.allCases) { scale in
                    Button {
                        setVisibleDuration(scale.duration)
                        Haptics.selection()
                    } label: {
                        Label(scale.title, systemImage: isAtScale(scale) ? "checkmark" : "magnifyingglass")
                    }
                }
            } label: {
                VStack(spacing: 2) {
                    Text("Scale")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(scaleDisplay.compact)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(BBTheme.oxblood)
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Ranking history scale, \(scaleDisplay.title)")
            .accessibilityHint("Choose a visible time window")

            Button { stepScale(toward: .smaller) } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
            .background(BBTheme.surface, in: RoundedRectangle(cornerRadius: BBTheme.Radius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BBTheme.Radius.small, style: .continuous)
                    .stroke(BBTheme.hairline)
            }
            .disabled(!canZoomIn)
            .opacity(canZoomIn ? 1 : 0.35)
            .accessibilityLabel("Zoom in on ranking history")
        }
        .foregroundStyle(BBTheme.ink)
        .frame(maxWidth: .infinity)
    }

    private var restaurantSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow("Restaurants")
                Spacer()
                Text("\(selectedLocationIDs.count) shown")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(selectionItems) { item in
                        Button {
                            toggleSelection(item.id)
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(item.color)
                                    .frame(width: 8, height: 8)
                                Text(item.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Image(systemName: item.isSelected ? "checkmark" : "plus")
                                    .font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(item.isSelected ? BBTheme.ink : .secondary)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 36)
                            .background(item.isSelected ? item.color.opacity(0.13) : BBTheme.surface, in: Capsule())
                            .overlay(Capsule().stroke(item.isSelected ? item.color.opacity(0.45) : BBTheme.hairline))
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("\(item.name), \(item.isSelected ? "shown" : "hidden")")
                        .accessibilityHint(item.isSelected ? "Hides this restaurant from the chart" : "Shows this restaurant on the chart")
                    }
                }
            }
            .contentMargins(.horizontal, 0)
        }
    }

    private var selectionItems: [RankingHistorySelectionItem] {
        let namesByID = Dictionary(uniqueKeysWithValues: store.locations.map { ($0.id, $0.name) })
        return locationIDs.enumerated().map { index, id in
            RankingHistorySelectionItem(
                id: id,
                name: namesByID[id] ?? "Restaurant",
                color: chartColor(at: index),
                isSelected: selectedLocationIDs.contains(id)
            )
        }
    }

    private var inputKey: RankingHistoryInputKey {
        RankingHistoryInputKey(
            revision: store.revision,
            scope: scope,
            category: category?.rawValue,
            locationIDs: locationIDs
        )
    }

    private func rebuildHistory() {
        isPreparing = true
        let builder = RankingHistoryBuilder()
        let newSnapshots: [RankingHistorySnapshot]
        switch scope {
        case .person(let personID):
            newSnapshots = builder.personSnapshots(
                locations: store.locations,
                comparisons: store.comparisons,
                personID: personID
            )
        case .circle:
            newSnapshots = builder.circleSnapshots(
                locations: store.locations,
                comparisons: store.comparisons,
                personIDs: store.circleMembers.map(\.id)
            )
        }
        snapshots = newSnapshots
        if !hasChosenInitialScale {
            visibleDuration = recommendedVisibleDuration(for: newSnapshots)
            hasChosenInitialScale = true
        }
        if let latestDate = newSnapshots.last?.date {
            scrollPosition = latestDate.addingTimeInterval(-visibleDuration * 0.75)
        }
        isPreparing = false
    }

    private var selectedLocationIDs: Set<UUID> {
        let availableIDs = locationIDs.filter { id in snapshots.contains { snapshot in snapshot.scores.contains { $0.id == id } } }
        let validSelection = selectedIDs.intersection(Set(availableIDs))
        if !validSelection.isEmpty { return validSelection }
        return Set(availableIDs.prefix(initialSeriesCount))
    }

    private func toggleSelection(_ id: UUID) {
        var updated = selectedLocationIDs
        if updated.contains(id) {
            guard updated.count > 1 else { return }
            updated.remove(id)
        } else {
            updated.insert(id)
        }
        if reduceMotion {
            selectedIDs = updated
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { selectedIDs = updated }
        }
        Haptics.selection()
    }

    private var chartData: RankingHistoryChartData {
        let selected = selectedLocationIDs
        var points: [RankingHistoryChartPoint] = []
        var maximumRank = 1
        let latestDate = snapshots.last?.date

        for snapshot in snapshots {
            let frame = snapshot.scores
                .filter { category == nil || $0.category == category }
                .sorted { lhs, rhs in
                    let lhsRank = category == nil ? lhs.overallRank : lhs.categoryRank
                    let rhsRank = category == nil ? rhs.overallRank : rhs.categoryRank
                    return lhsRank < rhsRank
                }
            guard !frame.isEmpty else { continue }
            let ranks = tieAwareRanks(for: frame)
            maximumRank = max(maximumRank, frame.count)
            for score in frame where selected.contains(score.id) {
                guard let rank = ranks[score.id] else { continue }
                points.append(
                    RankingHistoryChartPoint(
                        locationID: score.id,
                        name: score.locationName,
                        date: snapshot.date,
                        rank: rank,
                        isCurrent: snapshot.date == latestDate
                    )
                )
            }
        }

        let dates = points.map(\.date)
        let lowerDate = dates.min() ?? Date.now.addingTimeInterval(-visibleDuration)
        let upperDate = dates.max() ?? Date.now
        let padding = max(60, min(visibleDuration * 0.1, 7 * 24 * 60 * 60))
        let windowLowerDate = upperDate.addingTimeInterval(-visibleDuration * 0.75)
        let windowUpperDate = windowLowerDate.addingTimeInterval(visibleDuration)
        let domainLowerBound = min(lowerDate.addingTimeInterval(-padding), windowLowerDate)
        let domainUpperBound = max(upperDate.addingTimeInterval(padding), windowUpperDate)
        let domain = domainLowerBound...domainUpperBound
        let orderedSeriesIDs = locationIDs.filter { id in
            snapshots.contains { snapshot in snapshot.scores.contains { $0.id == id } }
        }

        return RankingHistoryChartData(
            points: points,
            seriesKeys: orderedSeriesIDs.map(\.uuidString),
            colors: orderedSeriesIDs.indices.map { chartColor(at: $0) },
            maxRank: maximumRank,
            xDomain: domain,
            latestDate: latestDate
        )
    }

    private func tieAwareRanks(for scores: [RankingHistoryScore]) -> [UUID: Int] {
        var firstRankByScore: [Int: Int] = [:]
        var result: [UUID: Int] = [:]
        for score in scores {
            let rank = category == nil ? score.overallRank : score.categoryRank
            let listScore = Int(score.score.rounded())
            result[score.id] = firstRankByScore[listScore] ?? rank
            firstRankByScore[listScore] = min(firstRankByScore[listScore] ?? rank, rank)
        }
        return result
    }

    private var currentScale: RankingHistoryScale {
        RankingHistoryScale.allCases.min { lhs, rhs in
            abs(log(lhs.duration / visibleDuration)) < abs(log(rhs.duration / visibleDuration))
        } ?? .month
    }

    private func stepScale(toward direction: ScaleDirection) {
        let scales = RankingHistoryScale.allCases
        let nextScale: RankingHistoryScale?
        switch direction {
        case .smaller:
            nextScale = scales.last { $0.duration < visibleDuration - 1 }
        case .larger:
            nextScale = scales.first { $0.duration > visibleDuration + 1 }
        }
        guard let nextScale else { return }
        setVisibleDuration(nextScale.duration)
        Haptics.selection()
    }

    private func yAxisValues(for maximumRank: Int) -> [Double] {
        let resolvedMaximum = max(1, maximumRank)
        guard resolvedMaximum > 7 else {
            return Array(1...resolvedMaximum).map { -Double($0) }
        }
        let interval = Int(ceil(Double(resolvedMaximum - 1) / 6))
        var ranks = [1]
        var rank = 1 + interval
        while rank < resolvedMaximum {
            ranks.append(rank)
            rank += interval
        }
        ranks.append(resolvedMaximum)
        return ranks.uniqued().map { -Double($0) }
    }

    private var xAxisLabelCount: Int {
        switch currentScale {
        case .minutes, .hours: 4
        case .day, .week: 5
        case .month: 5
        case .year: 6
        }
    }

    private func axisLabel(for date: Date) -> String {
        switch currentScale {
        case .minutes, .hours:
            return date.formatted(date: .omitted, time: .shortened)
        case .day:
            return date.formatted(.dateTime.month(.abbreviated).day().hour())
        case .week, .month:
            return date.formatted(.dateTime.month(.abbreviated).day())
        case .year:
            return date.formatted(.dateTime.month(.abbreviated).year())
        }
    }

    private func chartColor(at index: Int) -> Color {
        let lightColors: [Color] = [
            BBTheme.oxblood,
            BBTheme.blueInk,
            BBTheme.sage,
            Color(red: 0.54, green: 0.31, blue: 0.18),
            Color(red: 0.35, green: 0.28, blue: 0.49),
            Color(red: 0.28, green: 0.46, blue: 0.43),
            Color(red: 0.64, green: 0.38, blue: 0.26),
            Color(red: 0.38, green: 0.40, blue: 0.25)
        ]
        let darkColors: [Color] = [
            BBTheme.oxblood,
            Color(red: 0.47, green: 0.74, blue: 0.78),
            BBTheme.sage,
            Color(red: 0.82, green: 0.58, blue: 0.39),
            Color(red: 0.71, green: 0.59, blue: 0.86),
            Color(red: 0.45, green: 0.76, blue: 0.68),
            Color(red: 0.88, green: 0.55, blue: 0.42),
            Color(red: 0.72, green: 0.74, blue: 0.47)
        ]
        let colors = colorScheme == .dark ? darkColors : lightColors
        return colors[index % colors.count]
    }

    private var canZoomIn: Bool { visibleDuration > minimumVisibleDuration + 1 }
    private var canZoomOut: Bool { visibleDuration < maximumVisibleDuration - 1 }

    private var scaleDisplay: (compact: String, title: String) {
        if let scale = RankingHistoryScale.allCases.first(where: isAtScale) {
            return (scale.compactTitle, scale.title)
        }
        let minutes = visibleDuration / 60
        if minutes < 60 {
            let value = max(1, Int(minutes.rounded()))
            return ("\(value)m", "\(value) minutes")
        }
        let hours = visibleDuration / (60 * 60)
        if hours < 24 {
            let value = max(1, Int(hours.rounded()))
            return ("\(value)h", "\(value) hours")
        }
        let days = visibleDuration / (24 * 60 * 60)
        if days < 14 {
            let value = max(1, Int(days.rounded()))
            return ("\(value)d", "\(value) days")
        }
        if days < 60 {
            let value = max(1, Int((days / 7).rounded()))
            return ("\(value)w", "\(value) weeks")
        }
        let value = max(1, Int((days / 31).rounded()))
        return ("\(value)mo", "\(value) months")
    }

    private func isAtScale(_ scale: RankingHistoryScale) -> Bool {
        abs(scale.duration - visibleDuration) <= max(1, scale.duration * 0.01)
    }

    private func setVisibleDuration(_ proposedDuration: TimeInterval, animated: Bool = true) {
        let newDuration = proposedDuration.clamped(to: minimumVisibleDuration...maximumVisibleDuration)
        guard abs(newDuration - visibleDuration) > 0.5 else { return }

        let oldDuration = visibleDuration
        let anchor = zoomAnchor(for: oldDuration)
        let newScrollPosition = anchor.date.addingTimeInterval(-newDuration * anchor.fraction)
        let changes = {
            visibleDuration = newDuration
            scrollPosition = newScrollPosition
        }
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.28), changes)
        } else {
            changes()
        }
    }

    private func zoomAnchor(for duration: TimeInterval) -> (date: Date, fraction: Double) {
        let windowEnd = scrollPosition.addingTimeInterval(duration)
        if let latestDate = snapshots.last?.date,
           latestDate >= scrollPosition,
           latestDate <= windowEnd {
            let fraction = (latestDate.timeIntervalSince(scrollPosition) / duration).clamped(to: 0.1...0.9)
            return (latestDate, fraction)
        }
        return (scrollPosition.addingTimeInterval(duration * 0.5), 0.5)
    }

    private func recommendedVisibleDuration(for snapshots: [RankingHistorySnapshot]) -> TimeInterval {
        let visibleIDs = Set(locationIDs)
        let dates = snapshots.compactMap { snapshot -> Date? in
            guard snapshot.scores.contains(where: { score in
                visibleIDs.contains(score.id) && (category == nil || score.category == category)
            }) else { return nil }
            return snapshot.date
        }
        guard let firstDate = dates.min(), let lastDate = dates.max() else {
            return RankingHistoryScale.month.duration
        }
        let desiredDuration = max(minimumVisibleDuration, lastDate.timeIntervalSince(firstDate) * 1.25)
        return RankingHistoryScale.allCases.first { $0.duration >= desiredDuration }?.duration ?? maximumVisibleDuration
    }

    private enum ScaleDirection { case smaller, larger }
}

private struct RankingHistorySelectionItem: Identifiable {
    let id: UUID
    let name: String
    let color: Color
    let isSelected: Bool
}
