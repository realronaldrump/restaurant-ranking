import SwiftUI

@MainActor
struct MoreView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(SyncCoordinator.self) private var sync

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BBTheme.Spacing.section) {
                circleCard
                toolSection(
                    title: "Your log",
                    tools: [
                        ("Want to Try", "A shortlist for next time", "bookmark.fill", .wantToTry),
                        ("Statistics", "Totals across your outings", "chart.bar.xaxis", .stats),
                        ("Find outings in photos", "Add past outings from your photos", "photo.stack", .backfill)
                    ]
                )
                toolSection(
                    title: "Settings",
                    tools: settingsTools
                )
            }
            .padding(.horizontal, BBTheme.Spacing.page)
            .padding(.bottom, 36)
            .readablePageWidth()
        }
        .editorialPage()
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: circleStatusTaskID) {
            guard let circleID = store.activeCircleID, sync.isSignedIn else { return }
            await sync.refreshMembers(circleID: circleID)
        }
    }

    private var circleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Circle")
                    Text(store.activeCircle?.name ?? "Your log")
                        .font(BBTheme.display(29))
                    Text(rosterSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Manage") { router.sheet = .circle }
                    .font(.callout.weight(.bold))
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .accessibilityIdentifier("open-sharing-button")
                    .accessibilityLabel("Manage circle")
            }
            HStack(spacing: -7) {
                ForEach(store.circleMembers) { person in
                    ZStack(alignment: .bottomTrailing) {
                        Text(person.name.prefix(1).uppercased()).font(.headline).foregroundStyle(BBTheme.cream)
                            .frame(width: 48, height: 48).background(Color(hex: person.colorHex), in: Circle()).overlay(Circle().stroke(BBTheme.paper, lineWidth: 2))
                        if isSyncing(person.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(BBTheme.cream, BBTheme.oxbloodFill)
                                .background(BBTheme.paper, in: Circle())
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(person.name + (isSyncing(person.id) ? ", has their own synced copy" : ", name only"))
                }
                if store.circleMembers.count < 6 {
                    Button { router.sheet = .circle } label: {
                        Image(systemName: "plus")
                            .frame(width: 48, height: 48)
                            .background(BBTheme.surfaceMuted, in: Circle())
                            .overlay(Circle().stroke(BBTheme.paper, lineWidth: 2))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Share this log with somebody")
                }
                Spacer()
            }
            Label(circleStatusTitle, systemImage: circleStatusSymbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(sync.isSignedIn ? BBTheme.oxblood : .secondary)
                .accessibilityIdentifier("circle-sync-status")
            Text(circleStatusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("circle-sync-detail")
        }
        .editorialCard()
    }

    private var rosterSummary: String {
        let count = store.circleMembers.count
        if count == 1 {
            return "1 person keeps their own reactions in this log."
        }
        return "\(count) people keep their own reactions in this log."
    }

    private func isSyncing(_ personID: UUID) -> Bool {
        sync.members.contains { $0.personID == personID }
    }

    private var circleStatusTitle: String {
        guard sync.isConfigured else { return "Only this iPhone has a copy" }
        guard sync.isSignedIn else { return "Only this iPhone has a copy" }
        if sync.isPreparing || sync.status.isBusy { return "Syncing…" }
        if case .offline = sync.status { return "Offline · saved on this iPhone" }
        if case .failed = sync.status { return "Sync needs attention" }
        return sync.members.count > 1 ? "\(sync.members.count) people synced" : "Backed up and encrypted"
    }

    private var circleStatusDetail: String {
        guard sync.isConfigured else {
            return "The names here are just labels for reactions. This build has no syncing, so the log stays on this iPhone."
        }
        guard sync.isSignedIn else {
            return "The names here are just labels for reactions. Sign in to back up this log or share it."
        }
        if case .failed = sync.status, let message = sync.lastError { return message }
        let connected = sync.members.count
        if connected > 1 {
            return "\(connected) people can open this log on their own device. A checkmark means they are synced."
        }
        if store.circleMembers.count > 1 {
            return "Only you can open this log on another device. The other names are just labels for reactions."
        }
        return "Only you can open this log on another device. Tap Manage to share it with someone."
    }

    private var circleStatusSymbol: String {
        guard sync.isSignedIn else { return "iphone" }
        if case .failed = sync.status { return "exclamationmark.triangle.fill" }
        if case .offline = sync.status { return "icloud.slash" }
        return sync.members.count > 1 ? "person.2.fill" : "lock.icloud.fill"
    }

    private var circleStatusTaskID: String {
        "\(store.activeCircleID?.uuidString ?? "none")-\(sync.isSignedIn)"
    }

    private typealias Tool = (title: String, detail: String, symbol: String, route: AppRoute)

    /// Merging is a chore, not a feature, so it only earns a row here when the
    /// app has actually found a pair worth deciding about. It stays permanently
    /// reachable from Settings for the times somebody knows about a duplicate
    /// the automatic checks cannot see.
    private var settingsTools: [Tool] {
        var tools: [Tool] = [
            ("Open settings", "People, permissions, sync, and backups", "gearshape", .settings)
        ]
        let duplicateCount = store.duplicateLocationSuggestions().count
        if duplicateCount > 0 {
            tools.append((
                "Merge duplicates",
                duplicateCount == 1
                    ? "1 restaurant may be listed twice"
                    : "\(duplicateCount) restaurants may be listed twice",
                "arrow.triangle.merge",
                .merge
            ))
        }
        return tools
    }

    private func toolSection(title: String, tools: [Tool]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeader(title)
            VStack(spacing: 0) {
                ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                    toolRow(tool.title, tool.detail, tool.symbol, tool.route)
                    if index < tools.count - 1 { Divider() }
                }
            }
            .editorialCard(padding: 12)
        }
    }

    private func toolRow(_ title: String, _ detail: String, _ symbol: String, _ route: AppRoute) -> some View {
        Button { router.morePath.append(route) } label: {
            HStack(spacing: 16) {
                IconTile(symbol: symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .frame(minHeight: 70)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0x6F1D2B
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
