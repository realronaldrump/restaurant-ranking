import CoreData
import XCTest
@testable import RestaurantLog

@MainActor
final class CoreDataLifetimeTests: XCTestCase {
    func testRelationshipArraysExcludeDeletedObjectsBeforeTheyCanBeDereferenced() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let location = makeLocation(in: context)
        let visit = makeVisit(in: context)
        visit.location = location

        let rating = makeRating(in: context)
        rating.visit = visit

        let reaction = makeDinerReaction(in: context)
        reaction.visit = visit

        let dish = makeDish(in: context)
        dish.location = location

        let dishEntry = makeDishEntry(in: context)
        dishEntry.dish = dish
        dishEntry.visit = visit

        let participant = makeParticipant(in: context)
        participant.visit = visit

        let photo = makePhoto(in: context)
        photo.visit = visit

        let session = makeImportSession(in: context)
        let link = makeImportLink(in: context)
        link.session = session

        try context.save()

        context.delete(visit)
        context.delete(rating)
        context.delete(reaction)
        context.delete(dish)
        context.delete(dishEntry)
        context.delete(participant)
        context.delete(photo)
        context.delete(link)

        XCTAssertTrue(location.visitArray.isEmpty)
        XCTAssertFalse(location.hasVisit(inPriceBand: 2))
        XCTAssertTrue(location.dishArray.isEmpty)
        XCTAssertTrue(visit.ratingArray.isEmpty)
        XCTAssertTrue(visit.dinerEntryReactionArray.isEmpty)
        XCTAssertTrue(visit.dishEntryArray.isEmpty)
        XCTAssertTrue(visit.participantArray.isEmpty)
        XCTAssertTrue(visit.photoArray.isEmpty)
        XCTAssertTrue(dish.entryArray.isEmpty)
        XCTAssertTrue(session.linkArray.isEmpty)
    }

    func testPhotoSnapshotsDoNotRetainDeletedManagedObjects() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let photo = makePhoto(in: context)
        photo.caption = "Safe after deletion"
        photo.thumbnailData = Data([1, 2])
        photo.fullData = Data([3, 4, 5])
        try context.save()

        let imageSnapshot = try XCTUnwrap(PhotoImageSnapshot(photo: photo))
        let viewerSnapshot = try XCTUnwrap(PhotoViewerSnapshot(photo: photo))

        context.delete(photo)

        XCTAssertNil(PhotoImageSnapshot(photo: photo))
        XCTAssertNil(PhotoViewerSnapshot(photo: photo))
        XCTAssertEqual(imageSnapshot.thumbnailData, Data([1, 2]))
        XCTAssertEqual(imageSnapshot.fullData, Data([3, 4, 5]))
        XCTAssertEqual(viewerSnapshot.caption, "Safe after deletion")
        XCTAssertEqual(viewerSnapshot.imageData, Data([3, 4, 5]))
    }

    private func makeLocation(in context: NSManagedObjectContext) -> RestaurantLocation {
        let value = RestaurantLocation(context: context)
        value.id = UUID()
        value.name = "Lifetime Cafe"
        value.categoryRaw = DiningCategory.fullService.rawValue
        value.latitude = 0
        value.longitude = 0
        value.hasCoordinates = false
        value.isClosed = false
        value.createdAt = .now
        value.updatedAt = .now
        return value
    }

    private func makeVisit(in context: NSManagedObjectContext) -> VisitEntity {
        let value = VisitEntity(context: context)
        value.id = UUID()
        value.date = .now
        value.dateKnowledgeRaw = VisitDateKnowledge.known.rawValue
        value.priceBand = 2
        value.latitude = 0
        value.longitude = 0
        value.hasCoordinates = false
        value.createdAt = .now
        value.isShared = false
        value.createdByID = UUID()
        return value
    }

    private func makeRating(in context: NSManagedObjectContext) -> RatingEntity {
        let value = RatingEntity(context: context)
        value.id = UUID()
        value.personID = UUID()
        value.reactionRaw = Reaction.liked.rawValue
        value.hazyMemory = false
        value.wouldOrderAgain = false
        value.hasWouldOrderAgain = false
        value.createdAt = .now
        return value
    }

    private func makeDinerReaction(in context: NSManagedObjectContext) -> DinerEntryReactionEntity {
        let value = DinerEntryReactionEntity(context: context)
        value.id = UUID()
        value.authorPersonID = UUID()
        value.targetPersonID = UUID()
        value.kindRaw = CoonReaction.merelyFine.rawValue
        value.createdAt = .now
        value.updatedAt = .now
        return value
    }

    private func makeDish(in context: NSManagedObjectContext) -> DishEntity {
        let value = DishEntity(context: context)
        value.id = UUID()
        value.name = "Toast"
        value.roleRaw = DishRole.entree.rawValue
        value.createdAt = .now
        value.isArchived = false
        return value
    }

    private func makeDishEntry(in context: NSManagedObjectContext) -> DishEntryEntity {
        let value = DishEntryEntity(context: context)
        value.id = UUID()
        value.personID = UUID()
        value.reactionRaw = Reaction.liked.rawValue
        value.wouldOrderAgain = true
        value.createdAt = .now
        return value
    }

    private func makeParticipant(in context: NSManagedObjectContext) -> VisitParticipantEntity {
        let value = VisitParticipantEntity(context: context)
        value.id = UUID()
        value.personID = UUID()
        value.statusRaw = VisitParticipationStatus.attended.rawValue
        value.createdAt = .now
        value.updatedAt = .now
        return value
    }

    private func makePhoto(in context: NSManagedObjectContext) -> PhotoEntity {
        let value = PhotoEntity(context: context)
        value.id = UUID()
        value.createdAt = .now
        return value
    }

    private func makeImportSession(in context: NSManagedObjectContext) -> ExternalImportSessionEntity {
        let value = ExternalImportSessionEntity(context: context)
        value.id = UUID()
        value.provider = "test"
        value.sourceNamespace = "lifetime"
        value.importedAt = .now
        value.restaurantsCreated = 0
        value.outingsCreated = 0
        value.photosAdded = 0
        value.dishesAdded = 0
        value.rankingsSeeded = 0
        return value
    }

    private func makeImportLink(in context: NSManagedObjectContext) -> ExternalImportLinkEntity {
        let value = ExternalImportLinkEntity(context: context)
        value.id = UUID()
        value.provider = "test"
        value.recordType = "photo"
        value.externalKey = UUID().uuidString
        value.targetID = UUID()
        value.createdByImport = true
        value.createdAt = .now
        value.updatedAt = .now
        return value
    }
}
