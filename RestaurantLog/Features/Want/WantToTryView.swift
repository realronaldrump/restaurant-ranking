import SwiftUI

private struct WantRemovalRequest: Identifiable {
    let entryID: UUID
    let locationID: UUID
    let locationName: String
    var id: UUID { entryID }
}

private struct WantRowModel: Identifiable {
    let id: UUID
    let locationID: UUID
    let locationName: String
    let categorySymbol: String
    let meta: String
}

@MainActor
struct WantToTryView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(SyncCoordinator.self) private var sync
    @State private var query = ""
    @State private var effectiveQuery = ""
    @State private var removalRequest: WantRemovalRequest?

    var body: some View {
        let rows = visibleRows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header(rows.count)
                if rows.isEmpty {
                    EmptyLogView(
                        title: query.isEmpty ? "Nothing saved yet" : "No matches",
                        message: query.isEmpty ? "Save restaurants here for your next outing." : "Try a broader search or clear the field.",
                        symbol: query.isEmpty ? "bookmark" : "magnifyingglass"
                    )
                    if query.isEmpty {
                        Button("Add a restaurant") { router.sheet = .addWant }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            HStack(spacing: 8) {
                                NavigationLink(value: AppRoute.location(row.locationID)) {
                                    HStack(spacing: 14) {
                                        IconTile(symbol: row.categorySymbol)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(row.locationName).font(BBTheme.display(21)).lineLimit(2)
                                            Text(row.meta)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open \(row.locationName) restaurant details")

                                Button { requestRemoval(row) } label: {
                                    Image(systemName: "bookmark.slash")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(BBTheme.oxblood)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(isSharedWithOthers ? "Remove \(row.locationName) for everyone" : "Remove \(row.locationName) from this log")
                                .accessibilityHint(isSharedWithOthers ? "Removes it from the shared list for everyone." : "Removes it from your list.")
                            }
                            .padding(.vertical, 8)
                            .contextMenu {
                                Button("Log an outing here", systemImage: "plus.circle") { router.sheet = .logMealAt(row.locationID) }
                                Button("Remove from Want to Try", systemImage: "bookmark.slash", role: .destructive) {
                                    requestRemoval(row)
                                }
                            }
                            if index < rows.count - 1 { Divider() }
                        }
                    }
                    .editorialCard(padding: 12)
                }
            }
            .padding(.horizontal, BBTheme.Spacing.page)
            .padding(.bottom, 36)
            .readablePageWidth()
        }
        .scrollDismissesKeyboard(.immediately)
        .editorialPage()
        .navigationTitle("Want to Try")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search the list")
        .task(id: query) {
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            effectiveQuery = query
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.sheet = .addWant } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a restaurant")
            }
        }
        .editorialPrompt(item: $removalRequest) { request in
            EditorialPrompt(
                "Remove from Want to Try?",
                message: isSharedWithOthers
                    ? "\(request.locationName) will be removed for everyone in \(store.activeCircle?.name ?? "your circle")."
                    : "\(request.locationName) will be removed from your list.",
                tone: .destructive,
                actions: [
                    .destructive(isSharedWithOthers ? "Remove for everyone" : "Remove from log") {
                        remove(request)
                    },
                    .cancel("Cancel")
                ]
            )
        }
    }

    private func header(_ count: Int) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(shortlistStatusTitle)
                Text(shortlistStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if count > 0 {
                Text("\(count)")
                    .font(BBTheme.score(28))
                    .foregroundStyle(BBTheme.oxblood)
                    .contentTransition(.numericText())
                    .accessibilityLabel("\(count) saved \(count == 1 ? "restaurant" : "restaurants")")
            }
        }
        .padding(.top, 8)
    }

    private var isSharedWithOthers: Bool {
        sync.members.count > 1
    }

    private var shortlistStatusTitle: String {
        isSharedWithOthers ? "Shared list" : "Your list"
    }

    private var shortlistStatusDetail: String {
        if isSharedWithOthers {
            return "Everyone synced to \(store.activeCircle?.name ?? "this log") sees changes here."
        }
        if sync.isSignedIn {
            return "Only your device is synced, so only you see this list."
        }
        return "Saved on this iPhone only."
    }

    private func requestRemoval(_ row: WantRowModel) {
        let request = WantRemovalRequest(
            entryID: row.id,
            locationID: row.locationID,
            locationName: row.locationName
        )
        if isSharedWithOthers {
            removalRequest = request
        } else {
            remove(request)
        }
    }

    private func remove(_ request: WantRemovalRequest) {
        removalRequest = nil
        guard let location = store.locations.first(where: { $0.id == request.locationID }) else { return }
        store.toggleWant(location)
        Haptics.selection()
    }

    private var visibleRows: [WantRowModel] {
        let peopleByID = Dictionary(uniqueKeysWithValues: store.people.map { ($0.id, $0.name) })
        return store.wantEntries.compactMap { entry in
            guard let location = entry.location else { return nil }
            let searchable = ([location.name, location.category.shortTitle, location.city ?? ""] + location.cuisines + location.tags)
                .joined(separator: " ")
            guard effectiveQuery.isEmpty || searchable.localizedCaseInsensitiveContains(effectiveQuery) else { return nil }
            let person = peopleByID[entry.addedByID] ?? "Someone"
            return WantRowModel(
                id: entry.id,
                locationID: location.id,
                locationName: location.name,
                categorySymbol: location.category.symbol,
                meta: "\(location.category.shortTitle) · Added by \(person) \(entry.addedAt.formatted(.relative(presentation: .named)))"
            )
        }
    }
}
