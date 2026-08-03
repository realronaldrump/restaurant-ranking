import SwiftUI

@MainActor
struct NotificationBellButton: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(NotificationInbox.self) private var inbox

    let destination: AppTab

    var body: some View {
        let count = inbox.unreadCount(
            circleID: store.activeCircleID,
            viewerID: store.currentPerson?.id
        )
        Button(action: open) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(BBTheme.cream)
                        .padding(.horizontal, count > 9 ? 4 : 0)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(BBTheme.oxbloodFill, in: Capsule())
                        .offset(x: 5, y: 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("notifications-button")
        .accessibilityLabel("Activity")
        .accessibilityValue(count == 0 ? "No unread activity" : "\(count) unread")
        .accessibilityHint("Shows activity from your circle")
    }

    private func open() {
        router.selectedTab = destination
        switch destination {
        case .more:
            router.morePath.append(.notifications)
        default:
            router.logPath.append(.notifications)
        }
        Haptics.selection()
    }
}

@MainActor
struct NotificationsView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(NotificationInbox.self) private var inbox

    private var visibleItems: [InAppNotificationItem] {
        inbox.visibleItems(circleID: store.activeCircleID, viewerID: store.currentPerson?.id)
    }

    private var unreadItems: [InAppNotificationItem] { visibleItems.filter(\.isUnread) }
    private var readItems: [InAppNotificationItem] { visibleItems.filter { !$0.isUnread } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BBTheme.Spacing.section) {
                if visibleItems.isEmpty {
                    EmptyLogView(
                        title: "You’re all caught up",
                        message: "When your circle adds a restaurant, shares an outing, or reacts to a diner entry, it will appear here.",
                        symbol: "bell"
                    )
                    .accessibilityIdentifier("notifications-empty")
                } else {
                    if !unreadItems.isEmpty {
                        notificationSection("New", items: unreadItems)
                    }
                    if !readItems.isEmpty {
                        notificationSection(unreadItems.isEmpty ? "Activity" : "Earlier", items: readItems)
                    }
                }
            }
            .padding(.horizontal, BBTheme.Spacing.page)
            .padding(.bottom, 36)
            .readablePageWidth()
        }
        .editorialPage()
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !unreadItems.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        inbox.markAllRead(circleID: store.activeCircleID, viewerID: store.currentPerson?.id)
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .accessibilityIdentifier("mark-all-notifications-read")
                    .accessibilityLabel("Mark all activity as read")
                }
            }
        }
        .task { inbox.refresh() }
    }

    private func notificationSection(_ title: String, items: [InAppNotificationItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeader(title)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        inbox.markRead(item.id)
                        open(item)
                    } label: {
                        notificationRow(item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("notification-row-\(item.id.uuidString)")
                    if index < items.count - 1 { Divider().padding(.leading, 70) }
                }
            }
            .editorialCard(padding: 12)
        }
    }

    private func notificationRow(_ item: InAppNotificationItem) -> some View {
        HStack(alignment: .top, spacing: 13) {
            IconTile(symbol: item.kind.symbol, emphasized: item.isUnread)
            VStack(alignment: .leading, spacing: 4) {
                Text(message(for: item))
                    .font(.callout.weight(item.isUnread ? .semibold : .regular))
                    .foregroundStyle(BBTheme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = detail(for: item) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(relativeDate(item.occurredAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if item.isUnread {
                Circle()
                    .fill(BBTheme.oxbloodFill)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func message(for item: InAppNotificationItem) -> String {
        let actor = item.actorPersonID.flatMap(store.person(id:))?.name ?? "Someone"
        let restaurant = item.locationID.flatMap { id in store.locations.first { $0.id == id } }?.name ?? "a restaurant"
        switch item.kind {
        case .restaurantAdded:
            return "\(actor) added \(restaurant) to the circle."
        case .outingAdded:
            return "\(actor) added you to an outing at \(restaurant)."
        case .dinerEntryAdded:
            return "\(actor) added a diner entry at \(restaurant)."
        case .dinerEntryReactionAdded:
            return "\(actor) reacted to \(restaurant)."
        case .stickerReactionAdded:
            return "\(actor) reacted to your diner entry at \(restaurant)."
        case .wantToTryAdded:
            return "\(actor) added \(restaurant) to Want to Try."
        }
    }

    private func detail(for item: InAppNotificationItem) -> String? {
        switch item.kind {
        case .dinerEntryReactionAdded:
            return item.detailRaw.flatMap { Reaction(rawValue: $0)?.title }
        case .stickerReactionAdded:
            return item.detailRaw.flatMap { CoonReaction(rawValue: $0)?.title }
        default:
            return nil
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private func open(_ item: InAppNotificationItem) {
        Haptics.selection()
        switch item.kind {
        case .restaurantAdded, .wantToTryAdded:
            guard let locationID = item.locationID else { return }
            append(.location(locationID))
        case .outingAdded:
            guard let visitID = item.visitID else { return }
            if item.targetPersonID == store.currentPerson?.id {
                router.sheet = .rateVisit(visitID)
            } else {
                append(.visit(visitID))
            }
        case .dinerEntryAdded, .dinerEntryReactionAdded, .stickerReactionAdded:
            guard let visitID = item.visitID else { return }
            append(.visit(visitID))
        }
    }

    private func append(_ route: AppRoute) {
        switch router.selectedTab {
        case .more:
            router.morePath.append(route)
        default:
            router.logPath.append(route)
        }
    }
}
