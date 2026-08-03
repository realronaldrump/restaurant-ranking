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

    struct Result: Sendable {
        var applied = 0
        var appliedKeys: [SyncKey] = []
        var deleted = 0
        var unresolvedReferences = 0
        var deferredKeys: [SyncKey] = []
    }

    private struct DeferredReference: Error {}

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
            if try delete(key, circleID: circleID, in: context) { result.deleted += 1 }
        }

        for key in applyKeys {
            guard let record = records[key], let payload = record.payload else { continue }
            do {
                try upsert(key: key, payload: payload, circleID: circleID, in: context)
                result.applied += 1
                result.appliedKeys.append(key)
            } catch is DeferredReference {
                result.unresolvedReferences += 1
                result.deferredKeys.append(key)
            }
        }

        if result.unresolvedReferences > 0 {
            // A record naming a parent that has not arrived yet is repaired on
            // the next pass, once the parent is present.
            logger.notice("Sync deferred \(result.unresolvedReferences, privacy: .public) record(s) with a reference that is not present yet.")
        }
        return result
    }

    // MARK: - Upsert

    private static func upsert(
        key: SyncKey,
        payload: Data,
        circleID: UUID,
        in context: NSManagedObjectContext
    ) throws {

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try SyncPayloadCodec.decode(type, from: payload)
        }

        func validateIdentity(_ id: UUID) throws {
            guard id == key.id else {
                throw SyncError.entityMismatch("\(key.kind.rawValue) identity")
            }
        }

        func validateCircle(_ embeddedCircleID: UUID?) throws {
            guard embeddedCircleID == nil || embeddedCircleID == circleID else {
                throw SyncError.entityMismatch("\(key.kind.rawValue) circle")
            }
        }

        func link<T: NSManagedObject>(_ type: T.Type, _ id: UUID?) throws -> T? {
            guard let id else { return nil }
            guard let object: T = try existing(type, id: id, in: context) else {
                throw DeferredReference()
            }
            if !(object is BrandEntity) {
                guard Self.circleID(for: object) == circleID else {
                    throw SyncError.entityMismatch("\(key.kind.rawValue) relationship")
                }
            }
            return object
        }

        func requiredLink<T: NSManagedObject>(_ type: T.Type, _ id: UUID?) throws -> T {
            guard let id, let object = try link(type, id) else {
                throw DeferredReference()
            }
            return object
        }

        switch key.kind {
        case .circle:
            let value = try decode(AppBackupArchive.CircleRecord.self)
            try validateIdentity(value.id)
            guard value.id == circleID else { throw SyncError.entityMismatch("circle scope") }
            let object: CircleEntity = try upsertObject(CircleEntity.self, id: value.id, in: context)
            object.name = value.name
            object.createdAt = value.createdAt

        case .brand:
            let value = try decode(AppBackupArchive.BrandRecord.self)
            try validateIdentity(value.id)
            let object: BrandEntity = try upsertObject(BrandEntity.self, id: value.id, in: context)
            object.name = value.name
            object.createdAt = value.createdAt

        case .person:
            let value = try decode(AppBackupArchive.PersonRecord.self)
            try validateIdentity(value.id)
            try validateCircle(value.circleID)
            let circle = try requiredLink(CircleEntity.self, value.circleID ?? circleID)
            let object: PersonEntity = try upsertObject(PersonEntity.self, id: value.id, in: context)
            object.name = value.name
            object.isMe = value.isMe
            object.isCircleMember = value.isCircleMember
            object.isArchived = value.isArchived
            object.colorHex = value.colorHex
            object.createdAt = value.createdAt
            object.circle = circle

        case .location:
            let value = try decode(AppBackupArchive.LocationRecord.self)
            try validateIdentity(value.id)
            try validateCircle(value.circleID)
            let circle = try requiredLink(CircleEntity.self, value.circleID ?? circleID)
            let brand = try link(BrandEntity.self, value.brandID)
            let object: RestaurantLocation = try upsertObject(RestaurantLocation.self, id: value.id, in: context)
            object.name = value.name
            object.category = value.category
            object.address = value.address
            object.city = value.city
            object.phone = value.phone
            object.urlString = value.urlString
            object.hoursText = value.hoursText
            if value.hasCoordinates,
               StoredCoordinatePolicy.isValid(latitude: value.latitude, longitude: value.longitude) {
                object.latitude = value.latitude
                object.longitude = value.longitude
                object.hasCoordinates = true
            } else {
                object.latitude = 0
                object.longitude = 0
                object.hasCoordinates = false
            }
            object.isClosed = value.isClosed
            object.sourceIdentifier = value.sourceIdentifier
            object.cuisines = value.cuisines
            object.tags = value.tags
            object.createdAt = value.createdAt
            if let createdByID = value.createdByID {
                object.createdByID = createdByID
            }
            object.updatedAt = value.updatedAt
            object.circle = circle
            object.brand = brand

        case .dish:
            let value = try decode(AppBackupArchive.DishRecord.self)
            try validateIdentity(value.id)
            let location = try requiredLink(RestaurantLocation.self, value.locationID)
            let object: DishEntity = try upsertObject(DishEntity.self, id: value.id, in: context)
            object.name = value.name
            object.role = value.role
            object.createdAt = value.createdAt
            object.isArchived = value.isArchived
            object.location = location

        case .visit:
            let value = try decode(AppBackupArchive.VisitRecord.self)
            try validateIdentity(value.id)
            try validateCircle(value.circleID)
            let circle = try requiredLink(CircleEntity.self, value.circleID ?? circleID)
            let location = try requiredLink(RestaurantLocation.self, value.locationID)
            let object: VisitEntity = try upsertObject(VisitEntity.self, id: value.id, in: context)
            object.date = value.date
            if let offsetSeconds = value.dateTimeZoneOffsetSeconds {
                object.dateTimeZoneOffsetSeconds = NSNumber(value: offsetSeconds)
            } else if value.dateKnowledge == .unknown {
                object.dateTimeZoneOffsetSeconds = nil
            }
            object.dateKnowledge = value.dateKnowledge ?? .known
            object.visitType = value.visitType
            object.priceBand = value.priceBand
            object.occasion = value.occasion
            object.memory = value.memory
            if value.hasCoordinates,
               StoredCoordinatePolicy.isValid(latitude: value.latitude, longitude: value.longitude) {
                object.latitude = value.latitude
                object.longitude = value.longitude
                object.hasCoordinates = true
            } else {
                object.latitude = 0
                object.longitude = 0
                object.hasCoordinates = false
            }
            object.createdAt = value.createdAt
            object.isShared = value.isShared
            object.createdByID = value.createdByID
            object.companionIDs = value.companionIDs
            object.circle = circle
            object.location = location

        case .participant:
            let value = try decode(AppBackupArchive.ParticipantRecord.self)
            try validateIdentity(value.id)
            let visit = try requiredLink(VisitEntity.self, value.visitID)
            let object: VisitParticipantEntity = try upsertObject(VisitParticipantEntity.self, id: value.id, in: context)
            object.personID = value.personID
            object.status = value.status
            object.memory = value.memory
            object.createdAt = value.createdAt
            object.updatedAt = value.updatedAt
            object.visit = visit

        case .rating:
            let value = try decode(AppBackupArchive.RatingRecord.self)
            try validateIdentity(value.id)
            let visit = try requiredLink(VisitEntity.self, value.visitID)
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
            object.visit = visit

        case .dinerEntryReaction:
            let value = try decode(AppBackupArchive.DinerEntryReactionRecord.self)
            try validateIdentity(value.id)
            guard value.authorPersonID != value.targetPersonID else {
                throw SyncError.entityMismatch("diner entry reaction people")
            }
            let visit = try requiredLink(VisitEntity.self, value.visitID)
            _ = try requiredLink(PersonEntity.self, value.authorPersonID)
            _ = try requiredLink(PersonEntity.self, value.targetPersonID)
            guard visit.rating(for: value.targetPersonID) != nil else { throw DeferredReference() }
            let object: DinerEntryReactionEntity = try upsertObject(
                DinerEntryReactionEntity.self,
                id: value.id,
                in: context
            )
            object.authorPersonID = value.authorPersonID
            object.targetPersonID = value.targetPersonID
            object.kind = value.kind
            object.createdAt = value.createdAt
            object.updatedAt = value.updatedAt
            object.visit = visit

        case .dishEntry:
            let value = try decode(AppBackupArchive.DishEntryRecord.self)
            try validateIdentity(value.id)
            let dish = try requiredLink(DishEntity.self, value.dishID)
            let visit = try requiredLink(VisitEntity.self, value.visitID)
            let object: DishEntryEntity = try upsertObject(DishEntryEntity.self, id: value.id, in: context)
            object.personID = value.personID
            object.reaction = value.reaction
            object.wouldOrderAgain = value.wouldOrderAgain
            object.createdAt = value.createdAt
            object.dish = dish
            object.visit = visit

        case .photo:
            let value = try decode(AppBackupArchive.PhotoRecord.self)
            try validateIdentity(value.id)
            let visit = try requiredLink(VisitEntity.self, value.visitID)
            let object: PhotoEntity = try upsertObject(PhotoEntity.self, id: value.id, in: context)
            object.personID = value.personID
            object.caption = value.caption
            object.createdAt = value.createdAt
            object.captureDate = value.captureDate
            if let offsetSeconds = value.captureTimeZoneOffsetSeconds {
                object.captureTimeZoneOffsetSeconds = NSNumber(value: offsetSeconds)
            } else if value.captureDate == nil {
                object.captureTimeZoneOffsetSeconds = nil
            }
            object.visit = visit
            // Blob columns are intentionally untouched. Bytes arrive separately
            // through Storage so a metadata sync never rewrites image data.

        case .comparison:
            let value = try decode(AppBackupArchive.ComparisonRecord.self)
            try validateIdentity(value.id)
            try validateCircle(value.circleID)
            let circle = try requiredLink(CircleEntity.self, value.circleID ?? circleID)
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
            object.circle = circle

        case .want:
            let value = try decode(AppBackupArchive.WantRecord.self)
            try validateIdentity(value.id)
            try validateCircle(value.circleID)
            let circle = try requiredLink(CircleEntity.self, value.circleID ?? circleID)
            let location = try requiredLink(RestaurantLocation.self, value.locationID)
            let object: WantEntryEntity = try upsertObject(WantEntryEntity.self, id: value.id, in: context)
            object.addedByID = value.addedByID
            object.addedAt = value.addedAt
            object.circle = circle
            object.location = location

        case .importSession:
            let value = try decode(AppBackupArchive.ExternalImportSessionRecord.self)
            try validateIdentity(value.id)
            try validateCircle(value.circleID)
            let circle = try requiredLink(CircleEntity.self, value.circleID ?? circleID)
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
            object.circle = circle

        case .importLink:
            let value = try decode(AppBackupArchive.ExternalImportLinkRecord.self)
            try validateIdentity(value.id)
            try validateCircle(value.circleID)
            let circle = try requiredLink(CircleEntity.self, value.circleID ?? circleID)
            let session = try link(ExternalImportSessionEntity.self, value.sessionID)
            let object: ExternalImportLinkEntity = try upsertObject(ExternalImportLinkEntity.self, id: value.id, in: context)
            object.provider = value.provider
            object.recordType = value.recordType
            object.externalKey = value.externalKey
            object.contentHash = value.contentHash
            object.targetID = value.targetID
            object.createdByImport = value.createdByImport ?? false
            object.createdAt = value.createdAt
            object.updatedAt = value.updatedAt
            object.circle = circle
            object.session = session
        }
    }

    // MARK: - Deletion

    private static func delete(
        _ key: SyncKey,
        circleID: UUID,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        // A tombstone has no decoded payload whose embedded circle can be
        // validated. Scope the local lookup through the object's relationship
        // graph so a colliding UUID from one circle can never erase another
        // circle's object on this device.
        if key.kind == .circle, key.id != circleID { return false }

        let entityName = self.entityName(for: key.kind)
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        let identity = NSPredicate(format: "id == %@", key.id as CVarArg)
        if let scope = deletionScopePredicate(for: key.kind, circleID: circleID) {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [identity, scope])
        } else {
            request.predicate = identity
        }
        request.fetchLimit = 1
        guard let object = try context.fetch(request).first else { return false }

        if let brand = object as? BrandEntity,
           ((brand.locations?.allObjects as? [RestaurantLocation]) ?? [])
           .contains(where: { $0.circle?.id != circleID }) {
            // BrandEntity is intentionally shared across circles. Removing its
            // row from one circle must not null out brand links in another.
            return false
        }
        context.delete(object)
        return true
    }

    /// Nil means the entity is global and needs a post-fetch scope check.
    private static func deletionScopePredicate(for kind: SyncKind, circleID: UUID) -> NSPredicate? {
        switch kind {
        case .circle:
            NSPredicate(format: "id == %@", circleID as CVarArg)
        case .brand:
            nil
        case .person, .location, .visit, .comparison, .want, .importSession, .importLink:
            NSPredicate(format: "circle.id == %@", circleID as CVarArg)
        case .dish:
            NSPredicate(format: "location.circle.id == %@", circleID as CVarArg)
        case .participant, .rating, .dinerEntryReaction, .dishEntry, .photo:
            NSPredicate(format: "visit.circle.id == %@", circleID as CVarArg)
        }
    }

    // MARK: - Lookup

    /// BrandEntity is the model's only intentionally global entity. Every
    /// other object has a direct or inherited circle scope that must match the
    /// authenticated record currently being applied.
    private static func circleID(for object: NSManagedObject) -> UUID? {
        switch object {
        case let value as CircleEntity: value.id
        case let value as PersonEntity: value.circle?.id
        case is BrandEntity: nil
        case let value as RestaurantLocation: value.circle?.id
        case let value as DishEntity: value.location?.circle?.id
        case let value as VisitEntity: value.circle?.id
        case let value as VisitParticipantEntity: value.visit?.circle?.id
        case let value as RatingEntity: value.visit?.circle?.id
        case let value as DinerEntryReactionEntity: value.visit?.circle?.id
        case let value as DishEntryEntity: value.visit?.circle?.id
        case let value as PhotoEntity: value.visit?.circle?.id
        case let value as ComparisonEntity: value.circle?.id
        case let value as WantEntryEntity: value.circle?.id
        case let value as ExternalImportSessionEntity: value.circle?.id
        case let value as ExternalImportLinkEntity: value.circle?.id
        default: nil
        }
    }

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
        case .dinerEntryReaction: "DinerEntryReactionEntity"
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
