import SwiftUI

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All", unrated = "Unrated", hazy = "Hazy", shared = "Shared", closed = "Closed"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .unrated: "questionmark.circle"
        case .hazy: "cloud.fog"
        case .shared: "person.2"
        case .closed: "door.left.hand.closed"
        }
    }
}

private struct HistorySearchRecord: Identifiable {
    let visit: VisitEntity
    let year: Int
    let searchableText: String
    let isUnrated: Bool
    let isHazy: Bool
    let isShared: Bool
    let isClosed: Bool
    var id: UUID { visit.id }
}

private struct HistoryYearSection: Identifiable {
    let year: Int
    let visits: [VisitEntity]
    var id: Int { year }
}

private struct HistorySnapshot {
    let count: Int
    let sections: [HistoryYearSection]
}

@MainActor
struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var effectiveQuery = ""
    @State private var filter: HistoryFilter = .all
    @State private var searchRecords: [HistorySearchRecord] = []
    @State private var isPreparing = true

    var body: some View {
        let snapshot = historySnapshot
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header(snapshot.count)
                filterStrip
                if isPreparing {
                    historyPlaceholder
                } else if snapshot.count == 0 {
                    EmptyLogView(
                        title: searchRecords.isEmpty ? "No visits yet" : "No matching visits",
                        message: searchRecords.isEmpty ? "Meals will appear here after you log them." : "Try another search or history filter.",
                        symbol: "book.pages"
                    )
                    if searchRecords.isEmpty {
                        Button("Log Your First Meal") { router.sheet = .logMeal }
                            .buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("Show Every Visit") { filter = .all; query = ""; effectiveQuery = "" }
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
        .searchable(text: $query, prompt: "Place, dish, companion, or memory")
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
                    .accessibilityLabel("Backfill from photos")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { router.historyPath.append(.atlas) } label: { Image(systemName: "map.fill") }
                    .accessibilityLabel("Open dining atlas")
                Button { router.sheet = .logMeal } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Log a meal")
            }
        }
    }

    private func header(_ count: Int) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Eyebrow("Every visit, kept")
                Text("The complete record")
                    .font(BBTheme.display(35))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Search every place, dish, companion, and memory.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(count)")
                    .font(BBTheme.score(38))
                    .foregroundStyle(BBTheme.oxblood)
                    .contentTransition(.numericText())
                Text(count == 1 ? "VISIT" : "VISITS")
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(HistoryFilter.allCases) { value in
                    FilterChip(title: value.rawValue, symbol: value.symbol, selected: filter == value) {
                        filter = value
                        Haptics.selection()
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("History filters")
    }

    private func historySection(_ section: HistoryYearSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(section.year))
                    .font(BBTheme.score(25))
                    .foregroundStyle(BBTheme.oxblood)
                Spacer()
                Text("\(section.visits.count) \(section.visits.count == 1 ? "visit" : "visits")")
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
                HStack { RoundedRectangle(cornerRadius: 12).frame(width: 56, height: 56); VStack(alignment: .leading) { Text("Restaurant name"); Text("Visit date") }; Spacer() }
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
            let filterMatches: Bool = switch filter {
            case .all: true
            case .unrated: record.isUnrated
            case .hazy: record.isHazy
            case .shared: record.isShared
            case .closed: record.isClosed
            }
            guard filterMatches else { return false }
            guard !effectiveQuery.isEmpty else { return true }
            return record.searchableText.localizedCaseInsensitiveContains(effectiveQuery)
        }
        let grouped = Dictionary(grouping: records, by: \.year)
        let sections = grouped.keys.sorted(by: >).map { year in
            HistoryYearSection(year: year, visits: (grouped[year] ?? []).map(\.visit))
        }
        return .init(count: records.count, sections: sections)
    }

    private func rebuildSearchRecords() {
        isPreparing = true
        let peopleByID = Dictionary(uniqueKeysWithValues: store.people.map { ($0.id, $0.name) })
        searchRecords = store.visits.map { visit in
            let people = Set(visit.companionIDs + [visit.createdByID]).compactMap { peopleByID[$0] }
            let searchable = [visit.location?.name, visit.location?.city, visit.memory]
                + visit.dishEntryArray.map { $0.dish?.name }
                + people.map(Optional.some)
            return HistorySearchRecord(
                visit: visit,
                year: Calendar.current.component(.year, from: visit.date),
                searchableText: searchable.compactMap { $0 }.joined(separator: " "),
                isUnrated: visit.ratingArray.isEmpty,
                isHazy: visit.ratingArray.contains(where: \.hazyMemory),
                isShared: store.isSharedVisit(visit),
                isClosed: visit.location?.isClosed == true
            )
        }
        isPreparing = false
    }
}
