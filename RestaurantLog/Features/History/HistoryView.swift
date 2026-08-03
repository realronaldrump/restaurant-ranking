import SwiftUI

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All outings", unrated = "No reaction yet", hazy = "Hazy memory", unknownDate = "Date unknown", closed = "Closed restaurants"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .unrated: "questionmark.circle"
        case .hazy: "cloud.fog"
        case .unknownDate: "calendar.badge.questionmark"
        case .closed: "door.left.hand.closed"
        }
    }
}

private enum HistoryScope: String, CaseIterable, Identifiable {
    case mine = "Mine"
    case roster = "Everyone"
    var id: String { rawValue }
}

private enum HistorySort: String, CaseIterable, Identifiable {
    case newest = "Newest first"
    case city = "City"

    var id: String { rawValue }
}

private struct HistorySearchRecord: Identifiable {
    let id: UUID
    let visit: VisitEntity
    let year: Int
    let city: String?
    let citySortKey: String?
    let searchableText: String
    let isUnrated: Bool
    let isHazy: Bool
    let hasUnknownDate: Bool
    let isClosed: Bool
    let belongsToCurrentPerson: Bool
}

private struct HistorySection: Identifiable {
    let id: String
    let title: String
    let visits: [VisitEntity]
}

private struct HistorySnapshot {
    let count: Int
    let sections: [HistorySection]
}

@MainActor
struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var effectiveQuery = ""
    @State private var filter: HistoryFilter = .all
    @State private var scope: HistoryScope = .mine
    @State private var sort: HistorySort = .newest
    @State private var searchRecords: [HistorySearchRecord] = []
    @State private var isPreparing = true

    var body: some View {
        let snapshot = historySnapshot
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if isShared { scopePicker }
                historyControls(snapshot.count)
                if isPreparing {
                    historyPlaceholder
                } else if snapshot.count == 0 {
                    EmptyLogView(
                        title: searchRecords.isEmpty ? "No outings yet" : "No matching outings",
                        message: searchRecords.isEmpty ? "Outings show up here after you log them." : "Try another search or filter.",
                        symbol: "book.pages"
                    )
                    if searchRecords.isEmpty {
                        Button("Log your first outing") { router.sheet = .logMeal }
                            .buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("Show every outing") { filter = .all; query = ""; effectiveQuery = "" }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                } else {
                    ForEach(snapshot.sections) { section in historySection(section) }
                }
            }
            .padding(.horizontal, BBTheme.Spacing.page)
            .padding(.bottom, 36)
            .readablePageWidth()
        }
        .scrollDismissesKeyboard(.immediately)
        .editorialPage()
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Restaurant, dish, person, or memory")
        .task(id: query) {
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            effectiveQuery = query
        }
        .task(id: store.revision) { rebuildSearchRecords() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { router.historyPath.append(.backfill) } label: { Image(systemName: "photo.on.rectangle.angled") }
                    .accessibilityLabel("Find past outings in photos")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { router.historyPath.append(.atlas) } label: { Image(systemName: "map.fill") }
                    .accessibilityLabel("Open dining atlas")
                Button { router.sheet = .logMeal } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Log an outing")
            }
        }
    }

    private var scopePicker: some View {
        Picker("History scope", selection: $scope) {
            ForEach(HistoryScope.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("history-scope")
        .padding(.top, 8)
    }

    private var isShared: Bool { store.circleMembers.count > 1 }

    private func historyControls(_ count: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            historyCount(count)
            Spacer(minLength: 8)
            historyFilterMenu
            historySortMenu
        }
    }

    private func historyCount(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(scope == .roster && isShared ? "Everyone’s outings" : "My outings")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count) \(count == 1 ? "outing" : "outings")")
                .font(BBTheme.display(25))
                .contentTransition(.numericText())
        }
    }

    private var historyFilterMenu: some View {
        Menu {
            ForEach(HistoryFilter.allCases) { value in
                Button {
                    filter = value
                    Haptics.selection()
                } label: {
                    Label(value.rawValue, systemImage: filter == value ? "checkmark" : value.symbol)
                }
            }
        } label: {
            Label(filter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(BBTheme.surface, in: Capsule())
                .overlay(Capsule().stroke(BBTheme.hairline))
        }
        .accessibilityLabel("History filter, \(filter.rawValue)")
    }

    private var historySortMenu: some View {
        Menu {
            ForEach(HistorySort.allCases) { value in
                Button {
                    sort = value
                    Haptics.selection()
                } label: {
                    Label(value.rawValue, systemImage: sort == value ? "checkmark" : "arrow.up.arrow.down")
                }
            }
        } label: {
            Label(sort.rawValue, systemImage: "arrow.up.arrow.down")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(BBTheme.surface, in: Capsule())
                .overlay(Capsule().stroke(BBTheme.hairline))
        }
        .accessibilityLabel("History sort, \(sort.rawValue)")
        .accessibilityIdentifier("history-sort")
    }

    private func historySection(_ section: HistorySection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(BBTheme.score(25))
                    .foregroundStyle(BBTheme.oxblood)
                Spacer()
                Text("\(section.visits.count) \(section.visits.count == 1 ? "outing" : "outings")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(section.visits.enumerated()), id: \.element.objectID) { index, visit in
                    Button { router.historyPath.append(.visit(visit.id)) } label: {
                        VisitRow(visit: visit).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    if index < section.visits.count - 1 { Divider() }
                }
            }
            .editorialCard(padding: 12)
        }
    }

    private var historyPlaceholder: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                HStack { RoundedRectangle(cornerRadius: 12).frame(width: 56, height: 56); VStack(alignment: .leading) { Text("Restaurant name"); Text("Outing date") }; Spacer() }
                    .padding(.vertical, 8)
                if index < 3 { Divider() }
            }
        }
        .editorialCard(padding: 12)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }

    private var historySnapshot: HistorySnapshot {
        let records = searchRecords.filter { record in
            guard record.visit.isAlive else { return false }
            guard !isShared || scope == .roster || record.belongsToCurrentPerson else { return false }
            let filterMatches: Bool = switch filter {
            case .all: true
            case .unrated: record.isUnrated
            case .hazy: record.isHazy
            case .unknownDate: record.hasUnknownDate
            case .closed: record.isClosed
            }
            guard filterMatches else { return false }
            guard !effectiveQuery.isEmpty else { return true }
            return record.searchableText.localizedCaseInsensitiveContains(effectiveQuery)
        }
        let sections: [HistorySection] = switch sort {
        case .newest: yearSections(for: records)
        case .city: citySections(for: records)
        }
        return .init(count: records.count, sections: sections)
    }

    private func yearSections(for records: [HistorySearchRecord]) -> [HistorySection] {
        let grouped = Dictionary(grouping: records, by: \.year)
        return grouped.keys.sorted { lhs, rhs in
            if lhs == Int.min { return false }
            if rhs == Int.min { return true }
            return lhs > rhs
        }.map { year in
            HistorySection(
                id: "year:\(year)",
                title: year == Int.min ? "Date unknown" : String(year),
                visits: (grouped[year] ?? []).sorted(by: recordComesBefore).map(\.visit)
            )
        }
    }

    private func citySections(for records: [HistorySearchRecord]) -> [HistorySection] {
        let grouped = Dictionary(grouping: records) { $0.citySortKey ?? "" }
        return grouped.keys.sorted(by: cityKeyComesBefore).map { cityKey in
            let cityRecords = (grouped[cityKey] ?? []).sorted(by: recordComesBefore)
            return HistorySection(
                id: "city:\(cityKey)",
                title: cityRecords.first?.city ?? "City unknown",
                visits: cityRecords.map(\.visit)
            )
        }
    }

    private func recordComesBefore(_ lhs: HistorySearchRecord, _ rhs: HistorySearchRecord) -> Bool {
        if lhs.visit.date != rhs.visit.date { return lhs.visit.date > rhs.visit.date }
        return lhs.id.uuidString < rhs.id.uuidString
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

    private func rebuildSearchRecords() {
        isPreparing = true
        let peopleByID = Dictionary(uniqueKeysWithValues: store.people.map { ($0.id, $0.name) })
        let currentPersonID = store.currentPerson?.id
        searchRecords = store.visits.map { visit in
            let city = normalizedCity(visit.location?.city)
            let participantIDs = visit.participantArray
                .filter { $0.status != .notThere }
                .map(\.personID)
            let people = Set(participantIDs.isEmpty ? visit.companionIDs + [visit.createdByID] : participantIDs)
                .compactMap { peopleByID[$0] }
            let searchable = [visit.location?.name, city, visit.memory]
                + visit.dishEntryArray.map { $0.dish?.name }
                + visit.participantArray.map(\.memory)
                + people.map(Optional.some)
            let currentStatus = currentPersonID.flatMap { visit.participant(for: $0)?.status }
            let belongsToCurrentPerson = currentPersonID.map { personID in
                if let currentStatus { return currentStatus != .notThere }
                return visit.createdByID == personID || visit.rating(for: personID) != nil || visit.companionIDs.contains(personID)
            } ?? false
            return HistorySearchRecord(
                id: visit.id,
                visit: visit,
                year: visit.dateKnowledge == .known
                    ? DiningDateContext.year(of: visit.date, offsetSeconds: visit.dateTimeZoneOffsetSeconds?.intValue)
                    : Int.min,
                city: city,
                citySortKey: city?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
                searchableText: searchable.compactMap { $0 }.joined(separator: " "),
                isUnrated: belongsToCurrentPerson
                    && currentStatus != .declined
                    && currentPersonID.map { visit.rating(for: $0) == nil } == true,
                isHazy: currentPersonID.flatMap { visit.rating(for: $0)?.hazyMemory } ?? false,
                hasUnknownDate: visit.dateKnowledge == .unknown,
                isClosed: visit.location?.isClosed == true,
                belongsToCurrentPerson: belongsToCurrentPerson
            )
        }
        isPreparing = false
    }
}
