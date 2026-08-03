import CoreData
import Foundation

/// Everything in one circle, encoded as sync records.
///
/// Photo *bytes* are deliberately absent. `PhotoEntity.fullData` and
/// `thumbnailData` use external binary storage, so Core Data only reads them
/// from disk when the property is touched. Building the snapshot without
/// touching them keeps a sync pass at a few hundred kilobytes no matter how
/// many meal photos the log holds. Photo bytes travel through the separate
/// Storage path and are never part of this record snapshot.
struct SyncSnapshot {
    var circleID: UUID
    var records: [SyncKey: LocalSyncRecord]
    var photoIDs: Set<UUID>

    subscript(_ key: SyncKey) -> LocalSyncRecord? { records[key] }
}

enum SyncSnapshotBuilder {
    /// Builds the snapshot on `context`'s queue. Call from a background context.
    static func build(circleID: UUID, in context: NSManagedObjectContext) throws -> SyncSnapshot {
        var records: [SyncKey: LocalSyncRecord] = [:]
        var photoIDs: Set<UUID> = []

        func add(_ record: LocalSyncRecord) { records[record.key] = record }

        // Circle. An absent circle is not an error: a device that has just
        // accepted an invitation has nothing locally yet, and an empty snapshot
        // is exactly what makes the first pull create the whole graph.
        let circles: [CircleEntity] = try fetch(in: context, predicate: NSPredicate(format: "id == %@", circleID as CVarArg))
        guard let circle = circles.first else {
            return SyncSnapshot(circleID: circleID, records: [:], photoIDs: [])
        }
        add(try SyncPayloadCodec.record(.circle, circle.id, AppBackupArchive.CircleRecord(
            id: circle.id, name: circle.name, createdAt: circle.createdAt
        )))

        // People
        let people: [PersonEntity] = try fetch(in: context, predicate: NSPredicate(format: "circle.id == %@", circleID as CVarArg))
        for person in people {
            add(try SyncPayloadCodec.record(.person, person.id, AppBackupArchive.PersonRecord(
                id: person.id, name: person.name, isMe: person.isMe,
                isCircleMember: person.isCircleMember, isArchived: person.isArchived, colorHex: person.colorHex,
                createdAt: person.createdAt, circleID: circleID
            )))
        }

        // Locations, and the brands they reference
        let locations: [RestaurantLocation] = try fetch(in: context, predicate: NSPredicate(format: "circle.id == %@", circleID as CVarArg))
        var brands: [UUID: BrandEntity] = [:]
        for location in locations {
            if let brand = location.brand { brands[brand.id] = brand }
            add(try SyncPayloadCodec.record(.location, location.id, AppBackupArchive.LocationRecord(
                id: location.id, name: location.name, category: location.category,
                address: location.address, city: location.city, phone: location.phone,
                urlString: location.urlString, hoursText: location.hoursText,
                latitude: location.latitude, longitude: location.longitude,
                hasCoordinates: location.hasCoordinates, isClosed: location.isClosed,
                sourceIdentifier: location.sourceIdentifier, cuisines: location.cuisines,
                tags: location.tags, createdAt: location.createdAt, createdByID: location.createdByID,
                updatedAt: location.updatedAt,
                circleID: circleID, brandID: location.brand?.id
            )))
        }
        for brand in brands.values {
            add(try SyncPayloadCodec.record(.brand, brand.id, AppBackupArchive.BrandRecord(
                id: brand.id, name: brand.name, createdAt: brand.createdAt
            )))
        }

        // Dishes
        let dishes: [DishEntity] = try fetch(in: context, predicate: NSPredicate(format: "location.circle.id == %@", circleID as CVarArg))
        for dish in dishes {
            add(try SyncPayloadCodec.record(.dish, dish.id, AppBackupArchive.DishRecord(
                id: dish.id, name: dish.name, role: dish.role,
                createdAt: dish.createdAt, isArchived: dish.isArchived,
                locationID: dish.location?.id
            )))
        }

        // Visits
        let visits: [VisitEntity] = try fetch(in: context, predicate: NSPredicate(format: "circle.id == %@", circleID as CVarArg))
        for visit in visits {
            add(try SyncPayloadCodec.record(.visit, visit.id, AppBackupArchive.VisitRecord(
                id: visit.id, date: visit.date, dateKnowledge: visit.dateKnowledge,
                dateTimeZoneOffsetSeconds: visit.dateTimeZoneOffsetSeconds?.intValue,
                visitType: visit.visitType, priceBand: visit.priceBand, occasion: visit.occasion,
                memory: visit.memory, latitude: visit.latitude, longitude: visit.longitude,
                hasCoordinates: visit.hasCoordinates, createdAt: visit.createdAt,
                isShared: visit.isShared, createdByID: visit.createdByID,
                companionIDs: visit.companionIDs, circleID: circleID, locationID: visit.location?.id
            )))
        }

        let visitScope = NSPredicate(format: "visit.circle.id == %@", circleID as CVarArg)

        // Participants
        let participants: [VisitParticipantEntity] = try fetch(in: context, predicate: visitScope)
        for participant in participants {
            add(try SyncPayloadCodec.record(.participant, participant.id, AppBackupArchive.ParticipantRecord(
                id: participant.id, personID: participant.personID, status: participant.status,
                memory: participant.memory, createdAt: participant.createdAt,
                updatedAt: participant.updatedAt, visitID: participant.visit?.id
            )))
        }

        // Ratings
        let ratings: [RatingEntity] = try fetch(in: context, predicate: visitScope)
        for rating in ratings {
            add(try SyncPayloadCodec.record(.rating, rating.id, AppBackupArchive.RatingRecord(
                id: rating.id, personID: rating.personID, reaction: rating.reaction,
                service: rating.service, atmosphere: rating.atmosphere, value: rating.value,
                hazyMemory: rating.hazyMemory, wouldOrderAgain: rating.wouldOrderAgain,
                hasWouldOrderAgain: rating.hasWouldOrderAgain, createdAt: rating.createdAt,
                visitID: rating.visit?.id
            )))
        }

        // Social reactions to diner entries. They are separate records so a
        // sticker authored by one member can never overwrite another member's
        // ranking evidence during an offline merge.
        let dinerEntryReactions: [DinerEntryReactionEntity] = try fetch(in: context, predicate: visitScope)
        for reaction in dinerEntryReactions {
            add(try SyncPayloadCodec.record(
                .dinerEntryReaction,
                reaction.id,
                AppBackupArchive.DinerEntryReactionRecord(
                    id: reaction.id,
                    authorPersonID: reaction.authorPersonID,
                    targetPersonID: reaction.targetPersonID,
                    kind: reaction.kind,
                    mascot: reaction.mascot,
                    createdAt: reaction.createdAt,
                    updatedAt: reaction.updatedAt,
                    visitID: reaction.visit?.id
                )
            ))
        }

        // Dish entries
        let dishEntries: [DishEntryEntity] = try fetch(in: context, predicate: visitScope)
        for entry in dishEntries {
            add(try SyncPayloadCodec.record(.dishEntry, entry.id, AppBackupArchive.DishEntryRecord(
                id: entry.id, personID: entry.personID, reaction: entry.reaction,
                wouldOrderAgain: entry.wouldOrderAgain, createdAt: entry.createdAt,
                dishID: entry.dish?.id, visitID: entry.visit?.id
            )))
        }

        // Photo metadata. Blob properties are left untouched on purpose.
        let photos: [PhotoEntity] = try fetch(in: context, predicate: visitScope)
        for photo in photos {
            photoIDs.insert(photo.id)
            add(try SyncPayloadCodec.record(.photo, photo.id, AppBackupArchive.PhotoRecord(
                id: photo.id, personID: photo.personID,
                thumbnailData: nil, fullData: nil,
                createdAt: photo.createdAt, captureDate: photo.captureDate,
                captureTimeZoneOffsetSeconds: photo.captureTimeZoneOffsetSeconds?.intValue,
                caption: photo.caption, visitID: photo.visit?.id
            )))
        }

        let circleScope = NSPredicate(format: "circle.id == %@", circleID as CVarArg)

        // Comparisons
        let comparisons: [ComparisonEntity] = try fetch(in: context, predicate: circleScope)
        for comparison in comparisons {
            add(try SyncPayloadCodec.record(.comparison, comparison.id, AppBackupArchive.ComparisonRecord(
                id: comparison.id, personID: comparison.personID,
                locationAID: comparison.locationAID, locationBID: comparison.locationBID,
                outcome: comparison.outcome, date: comparison.date, isAnchor: comparison.isAnchor,
                anchorValue: comparison.anchorValue,
                locationAEvidenceFingerprint: comparison.locationAEvidenceFingerprint,
                locationBEvidenceFingerprint: comparison.locationBEvidenceFingerprint,
                circleID: circleID
            )))
        }

        // Want to Try
        let wants: [WantEntryEntity] = try fetch(in: context, predicate: circleScope)
        for want in wants {
            add(try SyncPayloadCodec.record(.want, want.id, AppBackupArchive.WantRecord(
                id: want.id, addedByID: want.addedByID, addedAt: want.addedAt,
                circleID: circleID, locationID: want.location?.id
            )))
        }

        // External import bookkeeping
        let sessions: [ExternalImportSessionEntity] = try fetch(in: context, predicate: circleScope)
        for session in sessions {
            add(try SyncPayloadCodec.record(.importSession, session.id, AppBackupArchive.ExternalImportSessionRecord(
                id: session.id, provider: session.provider, sourceNamespace: session.sourceNamespace,
                importedAt: session.importedAt, exportDate: session.exportDate,
                restaurantsCreated: session.restaurantsCreated, outingsCreated: session.outingsCreated,
                photosAdded: session.photosAdded, dishesAdded: session.dishesAdded,
                rankingsSeeded: session.rankingsSeeded, circleID: circleID
            )))
        }

        let links: [ExternalImportLinkEntity] = try fetch(in: context, predicate: circleScope)
        for link in links {
            add(try SyncPayloadCodec.record(.importLink, link.id, AppBackupArchive.ExternalImportLinkRecord(
                id: link.id, provider: link.provider, recordType: link.recordType,
                externalKey: link.externalKey, contentHash: link.contentHash, targetID: link.targetID,
                createdByImport: link.createdByImport, createdAt: link.createdAt,
                updatedAt: link.updatedAt, circleID: circleID, sessionID: link.session?.id
            )))
        }

        return SyncSnapshot(circleID: circleID, records: records, photoIDs: photoIDs)
    }

    private static func fetch<T: NSManagedObject>(
        in context: NSManagedObjectContext,
        predicate: NSPredicate
    ) throws -> [T] {
        let request = NSFetchRequest<T>(entityName: String(describing: T.self))
        request.predicate = predicate
        request.returnsObjectsAsFaults = false
        return try context.fetch(request)
    }
}

enum SyncError: LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case circleKeyMissing
    case noActiveCircle
    case deviceIdentityMissing
    case deviceIdentityConflict
    case entityMismatch(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "This build has no sync service configured, so the log stays on this iPhone."
        case .notSignedIn:
            "Sign in to sync this circle across devices."
        case .circleKeyMissing:
            "This iPhone does not hold the key for that circle. Ask somebody in it for a new join code."
        case .noActiveCircle:
            "Choose a circle before syncing."
        case .deviceIdentityMissing:
            "This iPhone could not determine which person owns its dining log. Your data is unchanged."
        case .deviceIdentityConflict:
            "This iPhone's saved person does not match the member profile assigned to its account. Sync stopped so one person's data cannot be assigned to somebody else."
        case let .entityMismatch(name):
            "A synced record did not match the local model for \(name)."
        }
    }
}
