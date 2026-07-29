import CoreData
import Foundation
import OSLog

/// Writes decrypted remote records into the local store.
///
/// Every write is an upsert keyed by the record's UUID, which is what makes the
/// whole scheme idempotent: replaying the same pull twice, or resuming after a
/// dropped connection mid-batch, converges to the same graph.
enum SyncApplier {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.davis.bigbeautifulranking",
        category: "Sync"
    )

    struct Result {
        var applied = 0
        var deleted = 0
        var unresolvedReferences = 0
    }

    @discardableResult
    static func apply(
        records: [SyncKey: DecodedSyncRecord],
        applying applyKeys: [SyncKey],
        deleting deleteKeys: [SyncKey],
        circleID: UUID,
        in context: NSManagedObjectContext
    ) throws -> Result {
        var result = Result()

        // Deletions first, children before parents (deleteKeys arrives ordered).
        for key in deleteKeys {
            if try delete(key, in: context) { result.deleted += 1 }
        }

        for key in applyKeys {
            guard let record = records[key], let payload = record.payload else { continue }
            let resolved = try upsert(key: key, payload: payload, circleID: circleID, in: context)
            result.applied += 1
            if !resolved { result.unresolvedReferences += 1 }
        }

        if result.unresolvedReferences > 0 {
            // A record naming a parent that has not arrived yet is repaired on
            // the next pass, once the parent is present.
            logger.notice("Sync applied \(result.unresolvedReferences, privacy: .public) record(s) with a reference that is not present yet.")
        }
        return result
    }

    // MARK: - Upsert

    /// Returns false when a relationship could not be resolved.
    private static func upsert(
        key: SyncKey,
        payload: Data,
        circleID: UUID,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        var resolved = true

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try SyncPayloadCodec.decode(type, from: payload)
        }

        func link<T: NSManagedObject>(_ type: T.Type, _ id: UUID?) throws -> T? {
            guard let id else { return nil }
            guard let object: T = try existing(type, id: id, in: context) else {
                resolved = false
                return nil
            }
            return object
        }

        switch key.kind {
        case .circle:
            let value = try decode(AppBackupArchive.CircleRecord.self)
            let object: CircleEntity = try upsertObject(CircleEntity.self, id: value.id, in: context)
            object.name = value.name
            object.createdAt = value.createdAt

        case .brand:
            let value = try decode(AppBackupArchive.BrandRecord.self)
            let object: BrandEntity = try upsertObject(BrandEntity.self, id: value.id, in: context)
            object.name = value.name
            object.createdAt = value.createdAt

        case .person:
            let value = try decode(AppBackupArchive.PersonRecord.self)
            let object: PersonEntity = try upsertObject(PersonEntity.self, id: value.id, in: context)
            object.name = value.name
            object.isMe = value.isMe
            object.isCircleMember = value.isCircleMember
            object.colorHex = value.colorHex
            object.createdAt = value.createdAt
            object.circle = try link(CircleEntity.self, value.circleID ?? circleID)

        case .location:
            let value = try decode(AppBackupArchive.LocationRecord.self)
            let object: RestaurantLocation = try upsertObject(RestaurantLocation.self, id: value.id, in: context)
            object.name = value.name
            object.category = value.category
            object.address = value.address
            object.city = value.city
            object.phone = value.phone
            object.urlString = value.urlString
            object.hoursText = value.hoursText
            object.latitude = value.latitude
            object.longitude = value.longitude
            object.hasCoordinates = value.hasCoordinates
            object.isClosed = value.isClosed
            object.sourceIdentifier = value.sourceIdentifier
            object.cuisines = value.cuisines
            object.tags = value.tags
            object.createdAt = value.createdAt
            object.updatedAt = value.updatedAt
            object.circle = try link(CircleEntity.self, value.circleID ?? circleID)
            object.brand = try link(BrandEntity.self, value.brandID)

        case .dish:
            let value = try decode(AppBackupArchive.DishRecord.self)
            let object: DishEntity = try upsertObject(DishEntity.self, id: value.id, in: context)
            object.name = value.name
            object.role = value.role
            object.createdAt = value.createdAt
            object.isArchived = value.isArchived
            object.location = try link(RestaurantLocation.self, value.locationID)

        case .visit:
            let value = try decode(AppBackupArchive.VisitRecord.self)
            let object: VisitEntity = try upsertObject(VisitEntity.self, id: value.id, in: context)
            object.date = value.date
            object.dateKnowledge = value.dateKnowledge ?? .known
            object.visitType = value.visitType
            object.priceBand = value.priceBand
            object.occasion = value.occasion
            object.memory = value.memory
            object.latitude = value.latitude
            object.longitude = value.longitude
            object.hasCoordinates = value.hasCoordinates
            object.createdAt = value.createdAt
            object.isShared = value.isShared
            object.createdByID = value.createdByID
            object.companionIDs = value.companionIDs
            object.circle = try link(CircleEntity.self, value.circleID ?? circleID)
            object.location = try link(RestaurantLocation.self, value.locationID)

        case .participant:
            let value = try decode(AppBackupArchive.ParticipantRecord.self)
            let object: VisitParticipantEntity = try upsertObject(VisitParticipantEntity.self, id: value.id, in: context)
            object.personID = value.personID
            object.status = value.status
            object.memory = value.memory
            object.createdAt = value.createdAt
            object.updatedAt = value.updatedAt
            object.visit = try link(VisitEntity.self, value.visitID)

        case .rating:
            let value = try decode(AppBackupArchive.RatingRecord.self)
            let object: RatingEntity = try upsertObject(RatingEntity.self, id: value.id, in: context)
            object.personID = value.personID
            object.reaction = value.reaction
            object.service = value.service
            object.atmosphere = value.atmosphere
            object.value = value.value
            object.hazyMemory = value.hazyMemory
            object.wouldOrderAgain = value.wouldOrderAgain
            object.hasWouldOrderAgain = value.hasWouldOrderAgain
            object.createdAt = value.createdAt
            object.visit = try link(VisitEntity.self, value.visitID)

        case .dishEntry:
            let value = try decode(AppBackupArchive.DishEntryRecord.self)
            let object: DishEntryEntity = try upsertObject(DishEntryEntity.self, id: value.id, in: context)
            object.personID = value.personID
            object.reaction = value.reaction
            object.wouldOrderAgain = value.wouldOrderAgain
            object.createdAt = value.createdAt
            object.dish = try link(DishEntity.self, value.dishID)
            object.visit = try link(VisitEntity.self, value.visitID)

        case .photo:
            let value = try decode(AppBackupArchive.PhotoRecord.self)
            let object: PhotoEntity = try upsertObject(PhotoEntity.self, id: value.id, in: context)
            object.personID = value.personID
            object.caption = value.caption
            object.createdAt = value.createdAt
            object.captureDate = value.captureDate
            object.visit = try link(VisitEntity.self, value.visitID)
            // Blob columns are intentionally untouched. Bytes arrive separately
            // through Storage so a metadata sync never rewrites image data.

        case .comparison:
            let value = try decode(AppBackupArchive.ComparisonRecord.self)
            let object: ComparisonEntity = try upsertObject(ComparisonEntity.self, id: value.id, in: context)
            object.personID = value.personID
            object.locationAID = value.locationAID
            object.locationBID = value.locationBID
            object.outcome = value.outcome
            object.date = value.date
            object.isAnchor = value.isAnchor
            object.anchorValue = value.anchorValue
            object.locationAEvidenceFingerprint = value.locationAEvidenceFingerprint ?? ""
            object.locationBEvidenceFingerprint = value.locationBEvidenceFingerprint ?? ""
            object.circle = try link(CircleEntity.self, value.circleID ?? circleID)

        case .want:
            let value = try decode(AppBackupArchive.WantRecord.self)
            let object: WantEntryEntity = try upsertObject(WantEntryEntity.self, id: value.id, in: context)
            object.addedByID = value.addedByID
            object.addedAt = value.addedAt
            object.circle = try link(CircleEntity.self, value.circleID ?? circleID)
            object.location = try link(RestaurantLocation.self, value.locationID)

        case .importSession:
            let value = try decode(AppBackupArchive.ExternalImportSessionRecord.self)
            let object: ExternalImportSessionEntity = try upsertObject(ExternalImportSessionEntity.self, id: value.id, in: context)
            object.provider = value.provider
            object.sourceNamespace = value.sourceNamespace
            object.importedAt = value.importedAt
            object.exportDate = value.exportDate
            object.restaurantsCreated = value.restaurantsCreated
            object.outingsCreated = value.outingsCreated
            object.photosAdded = value.photosAdded
            object.dishesAdded = value.dishesAdded
            object.rankingsSeeded = value.rankingsSeeded
            object.circle = try link(CircleEntity.self, value.circleID ?? circleID)

        case .importLink:
            let value = try decode(AppBackupArchive.ExternalImportLinkRecord.self)
            let object: ExternalImportLinkEntity = try upsertObject(ExternalImportLinkEntity.self, id: value.id, in: context)
            object.provider = value.provider
            object.recordType = value.recordType
            object.externalKey = value.externalKey
            object.contentHash = value.contentHash
            object.targetID = value.targetID
            object.createdByImport = value.createdByImport ?? false
            object.createdAt = value.createdAt
            object.updatedAt = value.updatedAt
            object.circle = try link(CircleEntity.self, value.circleID ?? circleID)
            object.session = try link(ExternalImportSessionEntity.self, value.sessionID)
        }

        return resolved
    }

    // MARK: - Deletion

    private static func delete(_ key: SyncKey, in context: NSManagedObjectContext) throws -> Bool {
        let entityName = self.entityName(for: key.kind)
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "id == %@", key.id as CVarArg)
        request.fetchLimit = 1
        guard let object = try context.fetch(request).first else { return false }
        context.delete(object)
        return true
    }

    // MARK: - Lookup

    private static func existing<T: NSManagedObject>(
        _ type: T.Type,
        id: UUID,
        in context: NSManagedObjectContext
    ) throws -> T? {
        let request = NSFetchRequest<T>(entityName: String(describing: T.self))
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        request.returnsObjectsAsFaults = false
        return try context.fetch(request).first
    }

    private static func upsertObject<T: NSManagedObject>(
        _ type: T.Type,
        id: UUID,
        in context: NSManagedObjectContext
    ) throws -> T {
        if let found: T = try existing(type, id: id, in: context) { return found }
        // insertNewObject rather than T(context:): init(context:) is a
        // convenience initialiser, so it cannot be called on a generic metatype.
        // Every entity in the model is named after its class, which makes the
        // name lookup exact.
        let created = NSEntityDescription.insertNewObject(
            forEntityName: String(describing: T.self),
            into: context
        )
        created.setValue(id, forKey: "id")
        guard let typed = created as? T else {
            throw SyncError.entityMismatch(String(describing: T.self))
        }
        return typed
    }

    private static func entityName(for kind: SyncKind) -> String {
        switch kind {
        case .circle: "CircleEntity"
        case .person: "PersonEntity"
        case .brand: "BrandEntity"
        case .location: "RestaurantLocation"
        case .visit: "VisitEntity"
        case .participant: "VisitParticipantEntity"
        case .rating: "RatingEntity"
        case .dish: "DishEntity"
        case .dishEntry: "DishEntryEntity"
        case .photo: "PhotoEntity"
        case .comparison: "ComparisonEntity"
        case .want: "WantEntryEntity"
        case .importSession: "ExternalImportSessionEntity"
        case .importLink: "ExternalImportLinkEntity"
        }
    }
}
