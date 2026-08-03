import CoreData
import Foundation

enum InAppNotificationKind: String, Codable, CaseIterable, Sendable {
    case restaurantAdded
    case outingAdded
    case dinerEntryAdded
    case dinerEntryReactionAdded
    case stickerReactionAdded
    case wantToTryAdded

    var symbol: String {
        switch self {
        case .restaurantAdded: "mappin.and.ellipse"
        case .outingAdded: "fork.knife.circle.fill"
        case .dinerEntryAdded: "note.text"
        case .dinerEntryReactionAdded: "hand.thumbsup.fill"
        case .stickerReactionAdded: "face.smiling"
        case .wantToTryAdded: "bookmark.fill"
        }
    }
}

enum InAppNotificationMutation: String, Codable, Sendable {
    case created
    case changed
}

struct NotificationActivityCandidate: Hashable, Sendable {
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
}

/// Extracts user-facing activity from records that were actually applied by a
/// successful remote sync pass. This type is pure aside from decoding payloads,
/// which keeps the notification rules independently testable.
enum NotificationActivityExtractor {
    static func extract(
        circleID: UUID,
        appliedKeys: [SyncKey],
        remote: [SyncKey: DecodedSyncRecord],
        local: [SyncKey: LocalSyncRecord],
        baseline: [SyncKey: String]
    ) -> [NotificationActivityCandidate] {
        let importedTargetIDs = importedTargetIDs(appliedKeys: appliedKeys, remote: remote, local: local)
        let newVisitIDs = Set(appliedKeys.compactMap { key -> UUID? in
            guard key.kind == .visit, baseline[key] == nil else { return nil }
            return key.id
        })
        let existingDinerEntries = existingDinerEntryKeys(local: local)

        var candidates: [NotificationActivityCandidate] = []
        for key in appliedKeys {
            guard let record = remote[key], !record.deleted,
                  let payload = record.payload,
                  record.deviceID != SyncDevice.identifier else { continue }

            let mutation: InAppNotificationMutation = baseline[key] == nil ? .created : .changed
            let occurredAt = Date(timeIntervalSince1970: Double(record.updatedMS) / 1_000)

            switch key.kind {
            case .location:
                guard mutation == .created,
                      !importedTargetIDs.contains(key.id),
                      let value = try? SyncPayloadCodec.decode(AppBackupArchive.LocationRecord.self, from: payload)
                else { continue }
                candidates.append(.init(
                    eventKey: eventKey(circleID, "restaurant", key.id.uuidString),
                    circleID: circleID,
                    kind: .restaurantAdded,
                    actorPersonID: value.createdByID,
                    targetPersonID: nil,
                    locationID: value.id,
                    visitID: nil,
                    detailRaw: nil,
                    audiencePersonIDs: [],
                    occurredAt: occurredAt
                ))

            case .visit:
                guard !importedTargetIDs.contains(key.id),
                      let value = try? SyncPayloadCodec.decode(AppBackupArchive.VisitRecord.self, from: payload)
                else { continue }
                let previous = local[key].flatMap {
                    try? SyncPayloadCodec.decode(AppBackupArchive.VisitRecord.self, from: $0.payload)
                }
                let audience = mutation == .created
                    ? value.companionIDs
                    : value.companionIDs.filter { !(previous?.companionIDs ?? []).contains($0) }
                for personID in audience where personID != value.createdByID {
                    candidates.append(.init(
                        eventKey: eventKey(
                            circleID, "outing", key.id.uuidString,
                            personID.uuidString, String(record.updatedMS)
                        ),
                        circleID: circleID,
                        kind: .outingAdded,
                        actorPersonID: value.createdByID,
                        targetPersonID: personID,
                        locationID: value.locationID,
                        visitID: value.id,
                        detailRaw: nil,
                        audiencePersonIDs: [personID],
                        occurredAt: occurredAt
                    ))
                }

            case .participant:
                // The visit record normally carries the audience. This fallback
                // covers a participant row arriving separately or later.
                guard mutation == .created,
                      let value = try? SyncPayloadCodec.decode(AppBackupArchive.ParticipantRecord.self, from: payload),
                      value.status == .pending,
                      let visitID = value.visitID,
                      let visit = visitRecord(
                        id: visitID,
                        remote: remote,
                        local: local
                      ),
                      localVisitRecord(id: visitID, local: local)?.companionIDs.contains(value.personID) != true,
                      value.personID != visit.createdByID,
                      !importedTargetIDs.contains(visitID) else { continue }
                candidates.append(.init(
                    eventKey: eventKey(
                        circleID, "outing", visitID.uuidString,
                        value.personID.uuidString, String(record.updatedMS)
                    ),
                    circleID: circleID,
                    kind: .outingAdded,
                    actorPersonID: visit.createdByID,
                    targetPersonID: value.personID,
                    locationID: visit.locationID,
                    visitID: visitID,
                    detailRaw: nil,
                    audiencePersonIDs: [value.personID],
                    occurredAt: occurredAt
                ))

            case .rating:
                guard let value = try? SyncPayloadCodec.decode(AppBackupArchive.RatingRecord.self, from: payload),
                      let visitID = value.visitID,
                      let visit = visitRecord(id: visitID, remote: remote, local: local),
                      !importedTargetIDs.contains(visitID),
                      !(newVisitIDs.contains(visitID) && visit.createdByID == value.personID) else { continue }
                candidates.append(.init(
                    eventKey: eventKey(circleID, "rating", key.id.uuidString, record.fingerprint ?? ""),
                    circleID: circleID,
                    kind: .dinerEntryReactionAdded,
                    actorPersonID: value.personID,
                    targetPersonID: nil,
                    locationID: visit.locationID,
                    visitID: visitID,
                    detailRaw: value.reaction.rawValue,
                    audiencePersonIDs: [],
                    occurredAt: occurredAt
                ))

            case .dinerEntryReaction:
                guard let value = try? SyncPayloadCodec.decode(AppBackupArchive.DinerEntryReactionRecord.self, from: payload),
                      let visitID = value.visitID,
                      let visit = visitRecord(id: visitID, remote: remote, local: local),
                      !importedTargetIDs.contains(visitID) else { continue }
                candidates.append(.init(
                    eventKey: eventKey(circleID, "sticker", key.id.uuidString, record.fingerprint ?? ""),
                    circleID: circleID,
                    kind: .stickerReactionAdded,
                    actorPersonID: value.authorPersonID,
                    targetPersonID: value.targetPersonID,
                    locationID: visit.locationID,
                    visitID: visitID,
                    detailRaw: value.kind.rawValue,
                    audiencePersonIDs: [value.targetPersonID],
                    occurredAt: occurredAt
                ))

            case .dishEntry:
                guard mutation == .created,
                      let value = try? SyncPayloadCodec.decode(AppBackupArchive.DishEntryRecord.self, from: payload),
                      let visitID = value.visitID,
                      let visit = visitRecord(id: visitID, remote: remote, local: local),
                      !importedTargetIDs.contains(visitID),
                      !existingDinerEntries.contains(dinerEntryKey(visitID: visitID, personID: value.personID)),
                      !(newVisitIDs.contains(visitID) && visit.createdByID == value.personID) else { continue }
                candidates.append(dinerEntryCandidate(
                    circleID: circleID, actorPersonID: value.personID, visitID: visitID,
                    locationID: visit.locationID, occurredAt: occurredAt
                ))

            case .photo:
                guard mutation == .created,
                      let value = try? SyncPayloadCodec.decode(AppBackupArchive.PhotoRecord.self, from: payload),
                      let personID = value.personID,
                      let visitID = value.visitID,
                      let visit = visitRecord(id: visitID, remote: remote, local: local),
                      !importedTargetIDs.contains(visitID),
                      !existingDinerEntries.contains(dinerEntryKey(visitID: visitID, personID: personID)),
                      !(newVisitIDs.contains(visitID) && visit.createdByID == personID) else { continue }
                candidates.append(dinerEntryCandidate(
                    circleID: circleID, actorPersonID: personID, visitID: visitID,
                    locationID: visit.locationID, occurredAt: occurredAt
                ))

            case .want:
                guard mutation == .created,
                      let value = try? SyncPayloadCodec.decode(AppBackupArchive.WantRecord.self, from: payload),
                      let locationID = value.locationID,
                      !importedTargetIDs.contains(locationID) else { continue }
                candidates.append(.init(
                    eventKey: eventKey(circleID, "want", key.id.uuidString),
                    circleID: circleID,
                    kind: .wantToTryAdded,
                    actorPersonID: value.addedByID,
                    targetPersonID: nil,
                    locationID: locationID,
                    visitID: nil,
                    detailRaw: nil,
                    audiencePersonIDs: [],
                    occurredAt: occurredAt
                ))

            case .circle, .person, .brand, .dish, .comparison, .importSession, .importLink:
                continue
            }
        }

        // A rating already describes the new diner entry. Dishes/photos added
        // alongside it should not create a second row for the same person.
        let ratedEntries = Set(candidates.compactMap { candidate -> String? in
            guard candidate.kind == .dinerEntryReactionAdded,
                  let visitID = candidate.visitID,
                  let actorID = candidate.actorPersonID else { return nil }
            return "\(visitID.uuidString)|\(actorID.uuidString)"
        })
        var seen = Set<String>()
        return candidates.filter { candidate in
            let entryKey: String? = candidate.kind == .dinerEntryAdded
                ? candidate.visitID.flatMap { visitID in candidate.actorPersonID.map { "\(visitID.uuidString)|\($0.uuidString)" } }
                : nil
            if let entryKey, ratedEntries.contains(entryKey) { return false }
            let dedupeKey: String
            if candidate.kind == .outingAdded,
               let visitID = candidate.visitID,
               let targetPersonID = candidate.targetPersonID {
                dedupeKey = "outing|\(visitID.uuidString)|\(targetPersonID.uuidString)"
            } else {
                dedupeKey = candidate.eventKey
            }
            return seen.insert(dedupeKey).inserted
        }
    }

    private static func dinerEntryCandidate(
        circleID: UUID,
        actorPersonID: UUID,
        visitID: UUID,
        locationID: UUID?,
        occurredAt: Date
    ) -> NotificationActivityCandidate {
        .init(
            eventKey: eventKey(circleID, "diner-entry", visitID.uuidString, actorPersonID.uuidString),
            circleID: circleID,
            kind: .dinerEntryAdded,
            actorPersonID: actorPersonID,
            targetPersonID: nil,
            locationID: locationID,
            visitID: visitID,
            detailRaw: nil,
            audiencePersonIDs: [],
            occurredAt: occurredAt
        )
    }

    private struct VisitReference {
        let id: UUID
        let createdByID: UUID
        let locationID: UUID?
        let companionIDs: [UUID]
    }

    private static func visitRecord(
        id: UUID,
        remote: [SyncKey: DecodedSyncRecord],
        local: [SyncKey: LocalSyncRecord]
    ) -> VisitReference? {
        let key = SyncKey(kind: .visit, id: id)
        if let record = remote[key], let payload = record.payload,
           let value = try? SyncPayloadCodec.decode(AppBackupArchive.VisitRecord.self, from: payload) {
            return visitReference(value)
        }
        return localVisitRecord(id: id, local: local)
    }

    private static func localVisitRecord(
        id: UUID,
        local: [SyncKey: LocalSyncRecord]
    ) -> VisitReference? {
        let key = SyncKey(kind: .visit, id: id)
        guard let record = local[key],
              let value = try? SyncPayloadCodec.decode(
                AppBackupArchive.VisitRecord.self,
                from: record.payload
              ) else { return nil }
        return visitReference(value)
    }

    private static func visitReference(_ value: AppBackupArchive.VisitRecord) -> VisitReference {
        .init(
            id: value.id,
            createdByID: value.createdByID,
            locationID: value.locationID,
            companionIDs: value.companionIDs
        )
    }

    private static func existingDinerEntryKeys(
        local: [SyncKey: LocalSyncRecord]
    ) -> Set<String> {
        Set(local.compactMap { key, record -> String? in
            switch key.kind {
            case .rating:
                guard let value = try? SyncPayloadCodec.decode(
                    AppBackupArchive.RatingRecord.self,
                    from: record.payload
                ), let visitID = value.visitID else { return nil }
                return dinerEntryKey(visitID: visitID, personID: value.personID)
            case .dishEntry:
                guard let value = try? SyncPayloadCodec.decode(
                    AppBackupArchive.DishEntryRecord.self,
                    from: record.payload
                ), let visitID = value.visitID else { return nil }
                return dinerEntryKey(visitID: visitID, personID: value.personID)
            case .photo:
                guard let value = try? SyncPayloadCodec.decode(
                    AppBackupArchive.PhotoRecord.self,
                    from: record.payload
                ), let visitID = value.visitID,
                   let personID = value.personID else { return nil }
                return dinerEntryKey(visitID: visitID, personID: personID)
            default:
                return nil
            }
        })
    }

    private static func dinerEntryKey(visitID: UUID, personID: UUID) -> String {
        "\(visitID.uuidString)|\(personID.uuidString)"
    }

    private static func importedTargetIDs(
        appliedKeys: [SyncKey],
        remote: [SyncKey: DecodedSyncRecord],
        local: [SyncKey: LocalSyncRecord]
    ) -> Set<UUID> {
        var result = Set<UUID>()
        let importKeys = Set(appliedKeys.filter { $0.kind == .importLink })
            .union(local.keys.filter { $0.kind == .importLink })
        for key in importKeys {
            guard !(remote[key]?.deleted ?? false),
                  let payload = remote[key]?.payload ?? local[key]?.payload,
                  let value = try? SyncPayloadCodec.decode(AppBackupArchive.ExternalImportLinkRecord.self, from: payload),
                  value.createdByImport == true else { continue }
            switch value.recordType {
            case "restaurant", "outing", "photo", "dish": result.insert(value.targetID)
            default: break
            }
        }
        return result
    }

    private static func eventKey(_ circleID: UUID, _ components: String...) -> String {
        ([circleID.uuidString] + components).joined(separator: "|")
    }
}

enum InAppNotificationPersistence {
    static let maximumPerCircle = 100

    @discardableResult
    static func insert(
        _ candidates: [NotificationActivityCandidate],
        receivedAt: Date = .now,
        into context: NSManagedObjectContext
    ) throws -> Int {
        guard !candidates.isEmpty else { return 0 }
        let circleIDs = Set(candidates.map(\.circleID))
        let request = NSFetchRequest<InAppNotificationEntity>(entityName: "InAppNotificationEntity")
        request.predicate = NSPredicate(format: "circleID IN %@", circleIDs.map(\.self))
        let existingKeys = Set(try context.fetch(request).map(\.eventKey))
        var inserted = 0
        var seen = existingKeys

        for candidate in candidates where seen.insert(candidate.eventKey).inserted {
            let object = InAppNotificationEntity(context: context)
            object.id = UUID()
            object.eventKey = candidate.eventKey
            object.circleID = candidate.circleID
            object.kindRaw = candidate.kind.rawValue
            object.actorPersonID = candidate.actorPersonID
            object.targetPersonID = candidate.targetPersonID
            object.locationID = candidate.locationID
            object.visitID = candidate.visitID
            object.detailRaw = candidate.detailRaw
            object.audiencePersonIDs = candidate.audiencePersonIDs
            object.occurredAt = candidate.occurredAt
            object.receivedAt = receivedAt
            inserted += 1
        }

        for circleID in circleIDs {
            try prune(circleID: circleID, in: context)
        }
        return inserted
    }

    private static func prune(circleID: UUID, in context: NSManagedObjectContext) throws {
        let request = NSFetchRequest<InAppNotificationEntity>(entityName: "InAppNotificationEntity")
        request.predicate = NSPredicate(format: "circleID == %@", circleID as CVarArg)
        let rows = try context.fetch(request).sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            if $0.receivedAt != $1.receivedAt { return $0.receivedAt > $1.receivedAt }
            return $0.eventKey < $1.eventKey
        }
        guard rows.count > maximumPerCircle else { return }
        let oldestFirst: (InAppNotificationEntity, InAppNotificationEntity) -> Bool = {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            if $0.receivedAt != $1.receivedAt { return $0.receivedAt < $1.receivedAt }
            return $0.eventKey > $1.eventKey
        }
        let read = rows.filter { $0.readAt != nil }.sorted(by: oldestFirst)
        let unread = rows.filter { $0.readAt == nil }.sorted(by: oldestFirst)
        var excess = rows.count - maximumPerCircle
        for row in read + unread where excess > 0 {
            context.delete(row)
            excess -= 1
        }
    }
}
