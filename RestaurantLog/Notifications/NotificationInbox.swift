import CoreData
import Foundation
import Observation

struct InAppNotificationItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let eventKey: String
    let circleID: UUID
    let kind: InAppNotificationKind
    let actorPersonID: UUID?
    let targetPersonID: UUID?
    let locationID: UUID?
    let visitID: UUID?
    let detailRaw: String?
    let audiencePersonIDs: [UUID]
    let occurredAt: Date
    let receivedAt: Date
    let readAt: Date?

    var isUnread: Bool { readAt == nil }
}

/// Main-actor presentation state for the device-local activity inbox.
/// Notification rows never enter the sync snapshot or backup archive.
@MainActor
@Observable
final class NotificationInbox {
    private(set) var items: [InAppNotificationItem] = []

    @ObservationIgnored private let persistence: PersistenceController
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []

    init(persistence: PersistenceController) {
        self.persistence = persistence
        observerTokens = [
            NotificationCenter.default.addObserver(
                forName: .syncDidApplyRemoteChanges,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            },
            NotificationCenter.default.addObserver(
                forName: .NSPersistentStoreRemoteChange,
                object: persistence.container.persistentStoreCoordinator,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        ]
        refresh()
    }

    func refresh() {
        let request = NSFetchRequest<InAppNotificationEntity>(entityName: "InAppNotificationEntity")
        request.sortDescriptors = [
            NSSortDescriptor(key: "occurredAt", ascending: false),
            NSSortDescriptor(key: "receivedAt", ascending: false),
            NSSortDescriptor(key: "eventKey", ascending: true)
        ]
        items = (try? persistence.container.viewContext.fetch(request))?.compactMap(Self.item) ?? []
    }

    private func scheduleRefresh() {
        Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func visibleItems(circleID: UUID?, viewerID: UUID?) -> [InAppNotificationItem] {
        guard let circleID else { return [] }
        return items.filter { isVisible($0, circleID: circleID, viewerID: viewerID) }
    }

    func unreadCount(circleID: UUID?, viewerID: UUID?) -> Int {
        visibleItems(circleID: circleID, viewerID: viewerID).count(where: \.isUnread)
    }

    func markRead(_ id: UUID) {
        let request = NSFetchRequest<InAppNotificationEntity>(entityName: "InAppNotificationEntity")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        guard let rows = try? persistence.container.viewContext.fetch(request),
              let row = rows.first else { return }
        row.readAt = .now
        try? persistence.save()
        refresh()
    }

    func markAllRead(circleID: UUID?, viewerID: UUID?) {
        let ids = Set(visibleItems(circleID: circleID, viewerID: viewerID).map(\.id))
        guard !ids.isEmpty else { return }
        let request = NSFetchRequest<InAppNotificationEntity>(entityName: "InAppNotificationEntity")
        request.predicate = NSPredicate(format: "id IN %@", ids.map(\.self))
        guard let rows = try? persistence.container.viewContext.fetch(request) else { return }
        rows.forEach { $0.readAt = $0.readAt ?? .now }
        try? persistence.save()
        refresh()
    }

    private func isVisible(
        _ item: InAppNotificationItem,
        circleID: UUID,
        viewerID: UUID?
    ) -> Bool {
        guard item.circleID == circleID else { return false }
        if let actorPersonID = item.actorPersonID, actorPersonID == viewerID { return false }
        if let targetPersonID = item.targetPersonID, targetPersonID != viewerID { return false }
        if !item.audiencePersonIDs.isEmpty {
            guard let viewerID, item.audiencePersonIDs.contains(viewerID) else { return false }
        }
        return true
    }

    private static func item(_ object: InAppNotificationEntity) -> InAppNotificationItem? {
        guard let kind = InAppNotificationKind(rawValue: object.kindRaw) else { return nil }
        return InAppNotificationItem(
            id: object.id,
            eventKey: object.eventKey,
            circleID: object.circleID,
            kind: kind,
            actorPersonID: object.actorPersonID,
            targetPersonID: object.targetPersonID,
            locationID: object.locationID,
            visitID: object.visitID,
            detailRaw: object.detailRaw,
            audiencePersonIDs: object.audiencePersonIDs,
            occurredAt: object.occurredAt,
            receivedAt: object.receivedAt,
            readAt: object.readAt
        )
    }
}
