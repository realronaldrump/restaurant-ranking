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
                        ("Settings & Privacy", "Circle, permissions, encrypted sync, and backup", "gearshape", .settings)
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
            await sync.refreshMembers(circleID: circleID)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Eyebrow("Your dining library")
            Text("More from your log").font(BBTheme.display(36))
            Text("See the bigger picture, maintain your records, and manage your private circle.")
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
                    Eyebrow("Private circle")
                    Text(store.activeCircle?.name ?? "Your Circle").font(BBTheme.display(29))
                }
                Spacer()
                if store.circles.count > 1 {
                    Menu {
                        ForEach(store.circles) { circle in
                            Button {
                                store.activateCircle(circle.id)
                            } label: {
                                Label(
                                    circle.name,
                                    systemImage: circle.id == store.activeCircleID ? "checkmark.circle.fill" : "circle"
                                )
                            }
                        }
                    } label: {
                        Label("Switch", systemImage: "arrow.left.arrow.right.circle.fill")
                    }
                    .font(.callout.weight(.bold))
                    .frame(minHeight: 44)
                }
                Button("Manage") { router.sheet = .shareCircle }
                    .font(.callout.weight(.bold))
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            }
            HStack(spacing: -7) {
                ForEach(store.circleMembers) { person in
                    ZStack(alignment: .bottomTrailing) {
                        Text(person.name.prefix(1).uppercased()).font(.headline).foregroundStyle(BBTheme.paper)
                            .frame(width: 48, height: 48).background(Color(hex: person.colorHex), in: Circle()).overlay(Circle().stroke(BBTheme.paper, lineWidth: 2))
                        if membership(for: person.id) != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white, BBTheme.oxblood)
                                .background(BBTheme.paper, in: Circle())
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(person.name + (membership(for: person.id) == nil ? ", invitation needed" : ", connected"))
                }
                if store.circleMembers.count < 6 {
                    Button { router.sheet = .shareCircle } label: {
                        Image(systemName: "plus")
                            .frame(width: 48, height: 48)
                            .background(BBTheme.surfaceMuted, in: Circle())
                            .overlay(Circle().stroke(BBTheme.paper, lineWidth: 2))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Add a circle member")
                }
                Spacer()
                Text("\(store.circleMembers.count) / 6").font(.caption).foregroundStyle(.secondary)
            }
            Label(circleStatusTitle, systemImage: circleStatusSymbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(circleIsSynced ? BBTheme.oxblood : .secondary)
            Text(circleStatusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .editorialCard()
    }

    private var circleIsSynced: Bool {
        guard let circleID = store.activeCircleID else { return false }
        return sync.isSyncing(circleID: circleID)
    }

    private var circleHasKey: Bool {
        guard let circleID = store.activeCircleID else { return false }
        return sync.hasCircleKey(circleID: circleID)
    }

    private var activeMemberships: [SupabaseClient.MembershipRow] {
        guard let circleID = store.activeCircleID else { return [] }
        return sync.memberships(circleID: circleID)
    }

    private var circleStatusTitle: String {
        guard sync.isConfigured else { return "Local only" }
        guard sync.isSignedIn else { return "Local only · Sign in to connect" }
        guard circleHasKey else { return "Local only · Finish sync setup" }
        guard circleIsSynced else { return "Sync paused on this iPhone" }
        return "Sync connected"
    }

    private var circleStatusDetail: String {
        guard circleHasKey else {
            return "This log is safe on this iPhone but is not yet shared with other devices. Tap Manage to connect it."
        }
        if !circleIsSynced { return "Syncing is paused on this iPhone. Tap Manage whenever you want to resume it." }
        let connected = activeMemberships.count
        let local = store.circleMembers.count
        if connected == 0 { return "Connected securely. Tap Manage to refresh member status or send an invitation." }
        return "\(connected) of \(local) circle member\(local == 1 ? "" : "s") connected. Checkmarks identify accounts that can sync this encrypted log."
    }

    private var circleStatusSymbol: String {
        circleIsSynced ? "lock.shield.fill" : (circleHasKey ? "pause.circle.fill" : "iphone")
    }

    private var circleStatusTaskID: String {
        let circle = store.activeCircleID?.uuidString ?? "none"
        return "\(circle)-\(sync.isSignedIn)-\(circleIsSynced)"
    }

    private func membership(for personID: UUID) -> SupabaseClient.MembershipRow? {
        activeMemberships.first { $0.personID == personID }
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
