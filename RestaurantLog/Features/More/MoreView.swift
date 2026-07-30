import SwiftUI

@MainActor
struct MoreView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(SyncCoordinator.self) private var sync

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BBTheme.Spacing.section) {
                pageHeader
                circleCard
                toolSection(
                    title: "Know your log",
                    eyebrow: "Insights",
                    tools: [
                        ("Statistics", "Patterns across your visits and ratings", "chart.bar.xaxis", .stats),
                        ("Settle the Score", "Clarify close calls in your ranking", "scale.3d", .settleScore)
                    ]
                )
                toolSection(
                    title: "Keep it tidy",
                    eyebrow: "Library",
                    tools: [
                        ("Backfill", "Add past visits from selected photos", "photo.stack", .backfill),
                        ("Merge Duplicates", "Combine records without losing history", "arrow.triangle.merge", .merge),
                        ("Settings & Privacy", "People, permissions, account, and backup", "gearshape", .settings)
                    ]
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
            await sync.refreshMembers(circleID: circleID, claiming: store.currentPerson?.id)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Eyebrow("Your dining library")
            Text("More from your log").font(BBTheme.display(36))
            Text("See the bigger picture, maintain your records, and share the log when you want to.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private var circleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(sync.isShared ? "Shared circle" : "Your dining log")
                    Text(sync.isShared ? (store.activeCircle?.name ?? "Your Circle") : "Just you")
                        .font(BBTheme.display(29))
                }
                Spacer()
                Button(sync.isShared ? "Manage" : "Share") { router.sheet = .circle }
                    .font(.callout.weight(.bold))
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .accessibilityIdentifier("open-sharing-button")
            }
            HStack(spacing: -7) {
                ForEach(store.circleMembers) { person in
                    ZStack(alignment: .bottomTrailing) {
                        Text(person.name.prefix(1).uppercased()).font(.headline).foregroundStyle(BBTheme.paper)
                            .frame(width: 48, height: 48).background(Color(hex: person.colorHex), in: Circle()).overlay(Circle().stroke(BBTheme.paper, lineWidth: 2))
                        if isSyncing(person.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white, BBTheme.oxblood)
                                .background(BBTheme.paper, in: Circle())
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(person.name + (isSyncing(person.id) ? ", syncing" : ", profile only"))
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
            Text(circleStatusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .editorialCard()
    }

    private func isSyncing(_ personID: UUID) -> Bool {
        sync.members.contains { $0.personID == personID }
    }

    private var circleStatusTitle: String {
        guard sync.isConfigured else { return "Kept on this iPhone" }
        guard sync.isSignedIn else { return "Sign in to back up & share" }
        if sync.isPreparing || sync.status.isBusy { return "Syncing…" }
        if case .offline = sync.status { return "Offline · saved on this iPhone" }
        if case .failed = sync.status { return "Sync needs attention" }
        return sync.members.count > 1 ? "Shared & encrypted" : "Backed up & encrypted"
    }

    private var circleStatusDetail: String {
        guard sync.isConfigured else {
            return "This build has no sync service configured, so the log stays on this iPhone."
        }
        guard sync.isSignedIn else {
            return "Sign in to keep an encrypted copy in your account. Until then this log exists only on this iPhone."
        }
        let connected = sync.members.count
        if connected > 1 {
            return "\(connected) people share this log. Checkmarks show who has their own copy syncing."
        }
        return "Nobody else can see this. Tap Share to send somebody a join code — everything here goes with them."
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

    private func toolSection(title: String, eyebrow: String, tools: [Tool]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeader(title, eyebrow: eyebrow)
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
