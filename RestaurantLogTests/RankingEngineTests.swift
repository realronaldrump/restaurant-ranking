import CoreLocation
import CoreData
import ImageIO
import MapKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import RestaurantLog

@MainActor
final class RankingEngineTests: XCTestCase {
    private var persistence: PersistenceController!
    private var store: AppStore!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "activeCircleID")
        UserDefaults.standard.removeObject(forKey: "devicePersonID")
        UserDefaults.standard.removeObject(forKey: "devicePersonIDsByCircle")
        persistence = PersistenceController(inMemory: true)
        store = AppStore(persistence: persistence)
        store.bootstrap(myName: "George")
        XCTAssertNotNil(store.addCircleMember(name: "Michelle"))
    }

    func testExistingComparisonStoreLightweightMigratesEvidenceFingerprints() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("comparison-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Legacy.sqlite")

        let legacyModel = try XCTUnwrap(ManagedObjectModel.make().copy() as? NSManagedObjectModel)
        let legacyComparison = try XCTUnwrap(legacyModel.entitiesByName["ComparisonEntity"])
        legacyComparison.properties.removeAll {
            $0.name == "locationAEvidenceFingerprint" || $0.name == "locationBEvidenceFingerprint"
        }
        let legacyContainer = NSPersistentContainer(name: "Legacy", managedObjectModel: legacyModel)
        let legacyDescription = NSPersistentStoreDescription(url: storeURL)
        legacyDescription.shouldAddStoreAsynchronously = false
        legacyContainer.persistentStoreDescriptions = [legacyDescription]
        var legacyLoadError: Error?
        legacyContainer.loadPersistentStores { _, error in legacyLoadError = error }
        if let legacyLoadError { throw legacyLoadError }

        let comparison = NSEntityDescription.insertNewObject(
            forEntityName: "ComparisonEntity", into: legacyContainer.viewContext
        )
        comparison.setValue(UUID(), forKey: "id")
        comparison.setValue(UUID(), forKey: "personID")
        comparison.setValue(UUID(), forKey: "locationAID")
        comparison.setValue(UUID(), forKey: "locationBID")
        comparison.setValue(ComparisonOutcome.a.rawValue, forKey: "outcomeRaw")
        comparison.setValue(Date.now, forKey: "date")
        try legacyContainer.viewContext.save()
        legacyContainer.viewContext.reset()
        if let legacyStore = legacyContainer.persistentStoreCoordinator.persistentStores.first {
            try legacyContainer.persistentStoreCoordinator.remove(legacyStore)
        }

        let currentContainer = NSPersistentContainer(name: "Current", managedObjectModel: ManagedObjectModel.make())
        let currentDescription = NSPersistentStoreDescription(url: storeURL)
        currentDescription.shouldAddStoreAsynchronously = false
        currentDescription.shouldMigrateStoreAutomatically = true
        currentDescription.shouldInferMappingModelAutomatically = true
        currentContainer.persistentStoreDescriptions = [currentDescription]
        var currentLoadError: Error?
        currentContainer.loadPersistentStores { _, error in currentLoadError = error }
        if let currentLoadError { throw currentLoadError }

        let request = NSFetchRequest<ComparisonEntity>(entityName: "ComparisonEntity")
        let migrated = try XCTUnwrap(currentContainer.viewContext.fetch(request).first)
        XCTAssertEqual(migrated.locationAEvidenceFingerprint, "")
        XCTAssertEqual(migrated.locationBEvidenceFingerprint, "")
        currentContainer.viewContext.reset()
        if let currentStore = currentContainer.persistentStoreCoordinator.persistentStores.first {
            try currentContainer.persistentStoreCoordinator.remove(currentStore)
        }
    }

    func testExistingStoreLightweightMigratesParticipantAndPhotoOwnershipFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("participant-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Legacy.sqlite")

        let legacyModel = try XCTUnwrap(ManagedObjectModel.make().copy() as? NSManagedObjectModel)
        let legacyVisit = try XCTUnwrap(legacyModel.entitiesByName["VisitEntity"])
        legacyVisit.properties.removeAll {
            $0.name == "participants" || $0.name == "dinerEntryReactions"
        }
        let legacyPhoto = try XCTUnwrap(legacyModel.entitiesByName["PhotoEntity"])
        legacyPhoto.properties.removeAll { $0.name == "personID" }
        legacyModel.entities.removeAll {
            $0.name == "VisitParticipantEntity" || $0.name == "DinerEntryReactionEntity"
        }

        let legacyContainer = NSPersistentContainer(name: "Legacy", managedObjectModel: legacyModel)
        let legacyDescription = NSPersistentStoreDescription(url: storeURL)
        legacyDescription.shouldAddStoreAsynchronously = false
        legacyContainer.persistentStoreDescriptions = [legacyDescription]
        var legacyLoadError: Error?
        legacyContainer.loadPersistentStores { _, error in legacyLoadError = error }
        if let legacyLoadError { throw legacyLoadError }

        let visitID = UUID()
        let visit = NSEntityDescription.insertNewObject(forEntityName: "VisitEntity", into: legacyContainer.viewContext)
        visit.setValue(visitID, forKey: "id")
        visit.setValue(Date.now, forKey: "date")
        visit.setValue(Date.now, forKey: "createdAt")
        visit.setValue(UUID(), forKey: "createdByID")
        let photo = NSEntityDescription.insertNewObject(forEntityName: "PhotoEntity", into: legacyContainer.viewContext)
        photo.setValue(UUID(), forKey: "id")
        photo.setValue(Date.now, forKey: "createdAt")
        photo.setValue(visit, forKey: "visit")
        try legacyContainer.viewContext.save()
        legacyContainer.viewContext.reset()
        if let legacyStore = legacyContainer.persistentStoreCoordinator.persistentStores.first {
            try legacyContainer.persistentStoreCoordinator.remove(legacyStore)
        }

        let currentContainer = NSPersistentContainer(name: "Current", managedObjectModel: ManagedObjectModel.make())
        let currentDescription = NSPersistentStoreDescription(url: storeURL)
        currentDescription.shouldAddStoreAsynchronously = false
        currentDescription.shouldMigrateStoreAutomatically = true
        currentDescription.shouldInferMappingModelAutomatically = true
        currentContainer.persistentStoreDescriptions = [currentDescription]
        var currentLoadError: Error?
        currentContainer.loadPersistentStores { _, error in currentLoadError = error }
        if let currentLoadError { throw currentLoadError }

        let visitRequest = NSFetchRequest<VisitEntity>(entityName: "VisitEntity")
        let migratedVisit = try XCTUnwrap(currentContainer.viewContext.fetch(visitRequest).first)
        XCTAssertEqual(migratedVisit.id, visitID)
        XCTAssertTrue(migratedVisit.participantArray.isEmpty)
        XCTAssertTrue(migratedVisit.dinerEntryReactionArray.isEmpty)
        XCTAssertNil(migratedVisit.photoArray.first?.personID)
        currentContainer.viewContext.reset()
        if let currentStore = currentContainer.persistentStoreCoordinator.persistentStores.first {
            try currentContainer.persistentStoreCoordinator.remove(currentStore)
        }
    }

    func testSingleLovedVisitLandsNearAbsoluteAnchor() {
        let place = store.createLocation(name: "Anchor House", category: .fullService)
        _ = store.logVisit(at: place, reaction: .loved)
        let score = try! XCTUnwrap(store.score(for: place))
        XCTAssertEqual(score.score, 85, accuracy: 2)
        XCTAssertTrue(score.isProvisional)
    }

    func testOptionalDetailsNeverMoveVisitMoreThanSevenPoints() {
        let place = store.createLocation(name: "Particulars", category: .fullService)
        let visit = store.logVisit(at: place, reaction: .fine)
        let rating = try! XCTUnwrap(visit.ratingArray.first)
        store.updateRating(rating, service: .loved, atmosphere: .loved, value: .loved, wouldOrderAgain: true)
        XCTAssertLessThanOrEqual(abs(store.rankingEngine.visitValue(visit: visit, rating: rating) - Reaction.fine.anchor), 7.0001)
    }

    func testCoonReactionIsOnePerAuthorAndDoesNotChangeTheRanking() throws {
        let me = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.otherCircleMembers.first)
        let place = store.createLocation(name: "Sticker Supper", category: .fullService)
        let visit = store.logVisit(
            at: place,
            reaction: .loved,
            personID: me.id,
            companionIDs: [michelle.id]
        )
        _ = store.addRating(to: visit, personID: michelle.id, reaction: .liked)
        let scoreBefore = try XCTUnwrap(store.score(for: place)?.score)

        XCTAssertTrue(store.setCoonReaction(.runItBack, to: michelle.id, in: visit))
        let first = try XCTUnwrap(store.myCoonReaction(to: michelle.id, in: visit))
        XCTAssertEqual(first.kind, .runItBack)
        XCTAssertEqual(store.coonReactions(to: michelle.id, in: visit).count, 1)

        XCTAssertTrue(store.setCoonReaction(.culinaryBetrayal, to: michelle.id, in: visit))
        let changed = try XCTUnwrap(store.myCoonReaction(to: michelle.id, in: visit))
        XCTAssertEqual(changed.id, first.id)
        XCTAssertEqual(changed.kind, .culinaryBetrayal)
        XCTAssertEqual(store.coonReactions(to: michelle.id, in: visit).count, 1)
        XCTAssertEqual(try XCTUnwrap(store.score(for: place)?.score), scoreBefore, accuracy: 0.0001)

        XCTAssertTrue(store.setCoonReaction(nil, to: michelle.id, in: visit))
        XCTAssertNil(store.myCoonReaction(to: michelle.id, in: visit))
    }

    func testCoonReactionRequiresAnotherMembersRatedEntry() throws {
        let me = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.otherCircleMembers.first)
        let place = store.createLocation(name: "Boundary Bistro")
        let visit = store.logVisit(
            at: place,
            reaction: .liked,
            personID: me.id,
            companionIDs: [michelle.id]
        )

        XCTAssertFalse(store.setCoonReaction(.noNotes, to: me.id, in: visit))
        XCTAssertFalse(store.setCoonReaction(.noNotes, to: michelle.id, in: visit))

        _ = store.addRating(to: visit, personID: michelle.id, reaction: .fine)
        XCTAssertTrue(store.setCoonReaction(.noNotes, to: michelle.id, in: visit))
    }

    func testMrBubblesStickerSharesTheSocialRecordAndNeverChangesTheRanking() throws {
        let me = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.otherCircleMembers.first)
        let place = store.createLocation(name: "Bubbles Supper", category: .fullService)
        let visit = store.logVisit(
            at: place,
            reaction: .loved,
            personID: me.id,
            companionIDs: [michelle.id]
        )
        _ = store.addRating(to: visit, personID: michelle.id, reaction: .liked)
        let scoreBefore = try XCTUnwrap(store.score(for: place)?.score)

        XCTAssertTrue(store.setStickerReaction(.runItBack, mascot: .mrBubbles, to: michelle.id, in: visit))
        let first = try XCTUnwrap(store.myStickerReaction(to: michelle.id, in: visit))
        XCTAssertEqual(first.mascot, .mrBubbles)
        XCTAssertEqual(first.mascotRaw, StickerMascot.mrBubbles.rawValue)
        XCTAssertEqual(store.stickerReactions(to: michelle.id, in: visit).count, 1)

        XCTAssertTrue(store.setStickerReaction(.noNotes, mascot: .coon, to: michelle.id, in: visit))
        let changed = try XCTUnwrap(store.myStickerReaction(to: michelle.id, in: visit))
        XCTAssertEqual(changed.id, first.id)
        XCTAssertEqual(changed.mascot, .coon)
        XCTAssertEqual(changed.kind, .noNotes)
        XCTAssertEqual(try XCTUnwrap(store.score(for: place)?.score), scoreBefore, accuracy: 0.0001)
    }

    func testThreeYearOldVisitCarriesAboutHalfWeight() {
        let recent = Date.now.addingTimeInterval(-30 * 86_400)
        let old = Date.now.addingTimeInterval(-3 * 365 * 86_400)
        XCTAssertEqual(store.rankingEngine.recencyWeight(visitDate: old, asOf: .now) / store.rankingEngine.recencyWeight(visitDate: recent, asOf: .now), 0.5, accuracy: 0.04)
    }

    func testUnratedVisitDoesNotEnterRankings() {
        let place = store.createLocation(name: "History Only", category: .bakeries)
        _ = store.logVisit(at: place, reaction: nil)
        XCTAssertNil(store.score(for: place))
        XCTAssertEqual(place.visitArray.count, 1)
    }

    func testFamiliarRestaurantSeedsRankingWithoutCreatingOuting() throws {
        let outingCount = store.visits.count

        let restaurant = try XCTUnwrap(
            store.seedFamiliarRestaurant(name: "Known Favorite", reaction: .loved)
        )

        XCTAssertEqual(store.visits.count, outingCount)
        let score = try XCTUnwrap(store.score(for: restaurant))
        XCTAssertEqual(score.ratedVisitCount, 0)
    }

    func testEstablishedPlaceMovementIsGuarded() {
        let place = store.createLocation(name: "Reliable", category: .coffeeTea)
        for offset in 0..<5 { _ = store.logVisit(at: place, reaction: .loved, date: .now.addingTimeInterval(Double(-offset * 30) * 86_400)) }
        let before = try! XCTUnwrap(store.score(for: place)).score
        _ = store.logVisit(at: place, reaction: .notForMe)
        let after = try! XCTUnwrap(store.score(for: place)).score
        XCTAssertLessThanOrEqual(abs(after - before), RankingEngine.establishedVisitMovementLimit + 0.15)
    }

    func testPhotoClusteringUsesTwoHoursAndFiveHundredFeet() {
        let data = Data([0])
        let base = BackfillPhoto(id: UUID(), fullData: data, thumbnailData: nil, date: .now, coordinate: .init(latitude: 40.76, longitude: -111.89))
        let nearby = BackfillPhoto(id: UUID(), fullData: data, thumbnailData: nil, date: .now.addingTimeInterval(60 * 60), coordinate: .init(latitude: 40.7602, longitude: -111.8902))
        let far = BackfillPhoto(id: UUID(), fullData: data, thumbnailData: nil, date: .now.addingTimeInterval(90 * 60), coordinate: .init(latitude: 40.80, longitude: -111.89))
        let clusters = ImageSanitizer.clusters([base, nearby, far])
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters.first?.photos.count, 2)
    }

    func testPhotoFirstMealUsesVerifiedCaptureTimeAndVisibleFallback() {
        let fallback = Date(timeIntervalSince1970: 1_800_000_000)
        let captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data([0])
        let captured = BackfillPhoto(
            id: UUID(), fullData: data, thumbnailData: nil,
            date: captureDate, coordinate: nil, captureDate: captureDate
        )
        let metadataFree = BackfillPhoto(
            id: UUID(), fullData: data, thumbnailData: nil,
            date: fallback.addingTimeInterval(-60), coordinate: nil
        )

        XCTAssertEqual(MealPhotoDraftPolicy.visitDate(for: captured, fallback: fallback), captureDate)
        XCTAssertEqual(MealPhotoDraftPolicy.visitDate(for: metadataFree, fallback: fallback), fallback)
        XCTAssertEqual(MealPhotoDraftPolicy.restaurantLookupRadius, 175)
    }

    func testPhotoClusteringDoesNotTreatFiveHundredMetersAsFiveHundredFeet() {
        let data = Data([0])
        let baseDate = Date.now
        let base = BackfillPhoto(
            id: UUID(), fullData: data, thumbnailData: nil, date: baseDate,
            coordinate: .init(latitude: 40.7600, longitude: -111.8900)
        )
        let twoHundredMetersAway = BackfillPhoto(
            id: UUID(), fullData: data, thumbnailData: nil, date: baseDate.addingTimeInterval(60),
            coordinate: .init(latitude: 40.7618, longitude: -111.8900)
        )

        XCTAssertEqual(ImageSanitizer.clusters([base, twoHundredMetersAway]).count, 2)
    }

    func testPhotoWithoutGPSDoesNotBridgeDistantLocationsIntoOneCluster() {
        let data = Data([0])
        let baseDate = Date.now
        let losAngeles = BackfillPhoto(
            id: UUID(), fullData: data, thumbnailData: nil, date: baseDate,
            coordinate: .init(latitude: 34.0522, longitude: -118.2437)
        )
        let missingGPS = BackfillPhoto(
            id: UUID(), fullData: data, thumbnailData: nil, date: baseDate.addingTimeInterval(30 * 60),
            coordinate: nil
        )
        let newYork = BackfillPhoto(
            id: UUID(), fullData: data, thumbnailData: nil, date: baseDate.addingTimeInterval(60 * 60),
            coordinate: .init(latitude: 40.7128, longitude: -74.0060)
        )

        let clusters = ImageSanitizer.clusters([losAngeles, missingGPS, newYork])

        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters.first?.photos.count, 2)
    }

    func testPhotoClusterCannotGrowPastTwoHoursThroughChaining() {
        let data = Data([0])
        let baseDate = Date.now
        let coordinate = CLLocationCoordinate2D(latitude: 40.7600, longitude: -111.8900)
        let photos = [0, 90, 180].map { minutes in
            BackfillPhoto(
                id: UUID(), fullData: data, thumbnailData: nil,
                date: baseDate.addingTimeInterval(TimeInterval(minutes * 60)), coordinate: coordinate
            )
        }

        XCTAssertEqual(ImageSanitizer.clusters(photos).count, 2)
    }

    func testPhotoClusterCoordinateAveragesAcrossTheAntimeridian() throws {
        let data = Data([0])
        let date = Date.now
        let cluster = BackfillCluster(id: UUID(), photos: [
            BackfillPhoto(
                id: UUID(), fullData: data, thumbnailData: nil, date: date,
                coordinate: .init(latitude: 0, longitude: 179.9997)
            ),
            BackfillPhoto(
                id: UUID(), fullData: data, thumbnailData: nil, date: date,
                coordinate: .init(latitude: 0, longitude: -179.9997)
            )
        ])

        let coordinate = try XCTUnwrap(cluster.coordinate)
        XCTAssertEqual(coordinate.latitude, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(abs(coordinate.longitude), 179.999)
    }

    func testHistoricalPhotoWithoutCaptureDateDoesNotSilentlyUseNow() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))

        XCTAssertNil(ImageSanitizer.process(data, date: nil))
    }

    func testImageSanitizerReadsSignedGPSAndTimezoneThenStripsMetadata() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            encoded, UTType.jpeg.identifier as CFString, 1, nil
        ))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:07:17 18:30:00",
                kCGImagePropertyExifOffsetTimeOriginal: "+10:00"
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 33.8688,
                kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 151.2093,
                kCGImagePropertyGPSLongitudeRef: "W"
            ]
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let photo = try XCTUnwrap(ImageSanitizer.process(encoded as Data, date: nil))
        let coordinate = try XCTUnwrap(photo.coordinate)
        XCTAssertEqual(coordinate.latitude, -33.8688, accuracy: 0.000_001)
        XCTAssertEqual(coordinate.longitude, -151.2093, accuracy: 0.000_001)
        let expectedDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-07-17T18:30:00+10:00"))
        XCTAssertEqual(photo.date.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(photo.captureDate).timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(photo.captureTimeZoneOffsetSeconds, 10 * 60 * 60)

        let sanitizedSource = try XCTUnwrap(CGImageSourceCreateWithData(photo.fullData as CFData, nil))
        let sanitizedProperties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(sanitizedSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertNil(sanitizedProperties[kCGImagePropertyGPSDictionary])
        let sanitizedExif = sanitizedProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(sanitizedExif?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(sanitizedExif?[kCGImagePropertyExifOffsetTimeOriginal])
    }

    func testCaptureOffsetKeepsTwoPMMealAtTwoPMAfterTravelingOneTimeZoneEast() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-07-17T20:00:00Z"))
        let originalOffset = -6 * 60 * 60 // 2:00 PM MDT
        let travelOffset = -5 * 60 * 60 // 3:00 PM CDT for the same instant

        let originalHour = DiningDateContext.calendar(offsetSeconds: originalOffset).component(.hour, from: instant)
        let travelHour = DiningDateContext.calendar(offsetSeconds: travelOffset).component(.hour, from: instant)
        XCTAssertEqual(originalHour, 14)
        XCTAssertEqual(travelHour, 15)
        XCTAssertEqual(
            DiningDateContext.stableDayKey(for: instant, offsetSeconds: originalOffset),
            "2024-07-17"
        )

        let location = store.createLocation(name: "Timezone Supper", category: .fullService)
        let visit = store.logVisit(
            at: location,
            reaction: .loved,
            date: instant,
            dateTimeZoneOffsetSeconds: originalOffset
        )
        store.addPhoto(
            fullData: Data([0x01]),
            thumbnailData: nil,
            to: visit,
            createdAt: instant,
            captureDate: instant,
            captureTimeZoneOffsetSeconds: originalOffset
        )

        XCTAssertEqual(visit.dateTimeZoneOffsetSeconds?.intValue, originalOffset)
        XCTAssertEqual(
            visit.formattedDateTime(dateStyle: .short, timeStyle: .short),
            DiningDateContext.format(instant, dateStyle: .short, timeStyle: .short, offsetSeconds: originalOffset)
        )
        XCTAssertNotEqual(
            visit.formattedDateTime(dateStyle: .short, timeStyle: .short),
            DiningDateContext.format(instant, dateStyle: .short, timeStyle: .short, offsetSeconds: travelOffset)
        )
        XCTAssertEqual(visit.photoArray.first?.captureTimeZoneOffsetSeconds?.intValue, originalOffset)
        XCTAssertEqual(
            DiningDateContext.calendar(offsetSeconds: visit.dateTimeZoneOffsetSeconds?.intValue).component(.hour, from: visit.date),
            14
        )
    }

    func testPhotoMetadataUpdatesVisitDateToEarliestCaptureAndResortsHistory() throws {
        let location = store.createLocation(name: "Photo Date", category: .fullService)
        let olderVisit = store.logVisit(
            at: location, reaction: .liked,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let visit = store.logVisit(
            at: location, reaction: .loved,
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let earliestCapture = Date(timeIntervalSince1970: 1_650_000_000)
        let laterCapture = Date(timeIntervalSince1970: 1_660_000_000)
        let fallbackOnlyDate = Date(timeIntervalSince1970: 1_600_000_000)
        let data = Data([0x01])
        let photos = [
            BackfillPhoto(
                id: UUID(), fullData: data, thumbnailData: nil,
                date: fallbackOnlyDate, coordinate: nil
            ),
            BackfillPhoto(
                id: UUID(), fullData: data, thumbnailData: nil,
                date: laterCapture, coordinate: nil, captureDate: laterCapture
            ),
            BackfillPhoto(
                id: UUID(), fullData: data, thumbnailData: nil,
                date: earliestCapture, coordinate: nil, captureDate: earliestCapture
            )
        ]

        store.updateVisitDateFromPhotoMetadata(visit, photos: photos)

        XCTAssertEqual(visit.date, earliestCapture)
        XCTAssertEqual(store.visits.map(\.id), [olderVisit.id, visit.id])
    }

    func testMetadataFreePhotoDoesNotChangeVisitDate() {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let location = store.createLocation(name: "No Photo Date", category: .fullService)
        let visit = store.logVisit(at: location, reaction: .liked, date: originalDate)
        let photo = BackfillPhoto(
            id: UUID(), fullData: Data([0x01]), thumbnailData: nil,
            date: .now, coordinate: nil
        )

        store.updateVisitDateFromPhotoMetadata(visit, photos: [photo])

        XCTAssertEqual(visit.date, originalDate)
    }

    func testLaterPhotoMetadataCannotReplaceAnEarlierVisitDateOrItsOffset() {
        let location = store.createLocation(name: "Paired Photo Time", category: .fullService)
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let originalOffset = -7 * 60 * 60
        let laterDate = originalDate.addingTimeInterval(3_600)
        let laterOffset = -6 * 60 * 60

        let directVisit = store.logVisit(
            at: location,
            reaction: .liked,
            date: originalDate,
            dateTimeZoneOffsetSeconds: originalOffset
        )
        store.updateVisitDateFromPhotoMetadata(
            directVisit,
            photos: [BackfillPhoto(
                id: UUID(),
                fullData: Data([0x01]),
                thumbnailData: nil,
                date: laterDate,
                coordinate: nil,
                captureDate: laterDate,
                captureTimeZoneOffsetSeconds: laterOffset
            )]
        )

        XCTAssertEqual(directVisit.date, originalDate)
        XCTAssertEqual(directVisit.dateTimeZoneOffsetSeconds?.intValue, originalOffset)

        let storedVisit = store.logVisit(
            at: location,
            reaction: .loved,
            date: originalDate,
            dateTimeZoneOffsetSeconds: originalOffset
        )
        store.addPhoto(
            fullData: Data([0x02]),
            thumbnailData: nil,
            to: storedVisit,
            createdAt: laterDate,
            captureDate: laterDate,
            captureTimeZoneOffsetSeconds: laterOffset
        )

        XCTAssertEqual(store.photoDateSyncCandidateCount, 0)
        XCTAssertEqual(store.syncVisitDatesWithStoredPhotoTimes(), 0)
        XCTAssertEqual(storedVisit.date, originalDate)
        XCTAssertEqual(storedVisit.dateTimeZoneOffsetSeconds?.intValue, originalOffset)
    }

    func testPhotoLibraryMetadataKeepsEmbeddedDateAndOffsetTogether() {
        let embeddedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let assetDate = embeddedDate.addingTimeInterval(24 * 60 * 60)
        let embeddedOffset = 9 * 60 * 60
        let photo = BackfillPhoto(
            id: UUID(),
            fullData: Data([0x01]),
            thumbnailData: nil,
            date: embeddedDate,
            coordinate: nil,
            captureDate: embeddedDate,
            captureTimeZoneOffsetSeconds: embeddedOffset
        )

        let corrected = PhotoLibraryScanner.photoByApplyingLibraryMetadata(
            photo,
            assetCreationDate: assetDate,
            assetCoordinate: nil
        )

        XCTAssertEqual(corrected.date, embeddedDate)
        XCTAssertEqual(corrected.captureDate, embeddedDate)
        XCTAssertEqual(corrected.captureTimeZoneOffsetSeconds, embeddedOffset)
    }

    func testPreviousVisitsCanSyncToTheirEarliestVerifiedPhotoCaptureTime() {
        let location = store.createLocation(name: "Earlier Photo Entry", category: .fullService)
        let visit = store.logVisit(
            at: location, reaction: .loved,
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let earliestPhotoDate = Date(timeIntervalSince1970: 1_650_000_000)
        store.addPhoto(
            fullData: Data([0x01]), thumbnailData: nil, to: visit,
            createdAt: Date(timeIntervalSince1970: 1_670_000_000),
            captureDate: Date(timeIntervalSince1970: 1_660_000_000)
        )
        store.addPhoto(
            fullData: Data([0x02]), thumbnailData: nil, to: visit,
            createdAt: Date(timeIntervalSince1970: 1_680_000_000),
            captureDate: earliestPhotoDate
        )

        XCTAssertEqual(store.photoDateSyncCandidateCount, 1)
        XCTAssertEqual(store.syncVisitDatesWithStoredPhotoTimes(), 1)

        XCTAssertEqual(visit.date, earliestPhotoDate)
        XCTAssertEqual(store.photoDateSyncCandidateCount, 0)
        XCTAssertEqual(store.syncVisitDatesWithStoredPhotoTimes(), 0)
    }

    func testLocationQualityRejectsStaleInvalidAndImpreciseReadings() {
        let now = Date(timeIntervalSince1970: 1_721_234_567)
        func location(age: TimeInterval, accuracy: CLLocationAccuracy) -> CLLocation {
            CLLocation(
                coordinate: .init(latitude: 40.7600, longitude: -111.8900),
                altitude: 0,
                horizontalAccuracy: accuracy,
                verticalAccuracy: -1,
                course: -1,
                speed: -1,
                timestamp: now.addingTimeInterval(-age)
            )
        }

        XCTAssertNotNil(LocationQualityPolicy.usableLocation(location(age: 10, accuracy: 25), asOf: now))
        XCTAssertNil(LocationQualityPolicy.usableLocation(location(age: 61, accuracy: 25), asOf: now))
        XCTAssertNil(LocationQualityPolicy.usableLocation(location(age: 10, accuracy: 201), asOf: now))
        XCTAssertNil(LocationQualityPolicy.usableLocation(location(age: 10, accuracy: -1), asOf: now))
    }

    func testNearbyRequestUsesDiningPointOfInterestCategories() throws {
        let center = CLLocationCoordinate2D(latitude: 39.4022, longitude: -107.2112)

        let request = LocationSearchPolicy.nearbyRequest(around: center, radius: 9_000)

        XCTAssertNil(request.naturalLanguageQuery)
        XCTAssertEqual(request.region.center.latitude, center.latitude, accuracy: 0.000_001)
        XCTAssertEqual(request.region.center.longitude, center.longitude, accuracy: 0.000_001)
        XCTAssertEqual(request.resultTypes, .pointOfInterest)
        let filter = try XCTUnwrap(request.pointOfInterestFilter)
        for category in LocationSearchPolicy.diningCategories {
            XCTAssertTrue(filter.includes(category), "Expected nearby search to include \(category.rawValue)")
        }
    }

    func testTextRequestTrimsTheQueryAndRejectsAnEmptyQuery() throws {
        let center = CLLocationCoordinate2D(latitude: 39.4022, longitude: -107.2112)

        let request = try XCTUnwrap(
            LocationSearchPolicy.textRequest("  White House Pizza  ", around: center, radius: 9_000)
        )

        XCTAssertEqual(request.naturalLanguageQuery, "White House Pizza")
        XCTAssertEqual(request.region.center.latitude, center.latitude, accuracy: 0.000_001)
        XCTAssertEqual(request.region.center.longitude, center.longitude, accuracy: 0.000_001)
        XCTAssertEqual(request.resultTypes, .pointOfInterest)
        XCTAssertNil(LocationSearchPolicy.textRequest("  \n ", around: center, radius: 9_000))
    }

    func testOrdinaryTextSearchDoesNotUseTheCurrentLocationAsAHardBoundary() {
        let currentLocation = CLLocationCoordinate2D(latitude: 39.7392, longitude: -104.9903)
        let explicitLocation = CLLocationCoordinate2D(latitude: 31.5493, longitude: -97.1467)

        let broadCenter = LocationSearchPolicy.textSearchCenter(
            explicit: nil,
            current: currentLocation
        )
        let explicitCenter = LocationSearchPolicy.textSearchCenter(
            explicit: explicitLocation,
            current: currentLocation
        )

        XCTAssertNil(broadCenter, "A typed search must be able to return restaurants outside the user's current area.")
        XCTAssertEqual(explicitCenter?.latitude, Optional(explicitLocation.latitude))
        XCTAssertEqual(explicitCenter?.longitude, Optional(explicitLocation.longitude))
    }

    func testMapErrorsBecomeUsefulMessagesInsteadOfFrameworkDescriptions() {
        let noMatch = NSError(domain: MKErrorDomain, code: Int(MKError.Code.placemarkNotFound.rawValue))
        let throttled = NSError(domain: MKErrorDomain, code: Int(MKError.Code.loadingThrottled.rawValue))
        let serverFailure = NSError(domain: MKErrorDomain, code: Int(MKError.Code.serverFailure.rawValue))

        XCTAssertNil(LocationSearchPolicy.userMessage(for: noMatch))
        XCTAssertEqual(
            LocationSearchPolicy.userMessage(for: throttled),
            "Map search is busy right now. Wait a moment and try again."
        )
        XCTAssertEqual(
            LocationSearchPolicy.userMessage(for: serverFailure),
            "Map search is temporarily unavailable. Try again."
        )
        XCTAssertFalse(
            LocationSearchPolicy.userMessage(for: NSError(domain: "Example", code: 1))?.contains("ErrorDomain") == true
        )
        XCTAssertEqual(
            LocationSearchPolicy.userMessage(for: NSError(domain: MKErrorDomain, code: -1)),
            "Map search couldn't be completed. Try again."
        )
    }

    func testVisitCoordinateRequiresARecentPreciseReadingNearTheRestaurant() {
        let now = Date(timeIntervalSince1970: 1_721_234_567)
        let restaurant = CLLocationCoordinate2D(latitude: 40.7600, longitude: -111.8900)
        func location(latitude: Double, accuracy: CLLocationAccuracy = 25) -> CLLocation {
            CLLocation(
                coordinate: .init(latitude: latitude, longitude: -111.8900),
                altitude: 0,
                horizontalAccuracy: accuracy,
                verticalAccuracy: -1,
                course: -1,
                speed: -1,
                timestamp: now.addingTimeInterval(-10)
            )
        }

        XCTAssertNotNil(LocationQualityPolicy.visitCoordinate(
            from: location(latitude: 40.7605), near: restaurant, asOf: now
        ))
        XCTAssertNil(LocationQualityPolicy.visitCoordinate(
            from: location(latitude: 40.7700), near: restaurant, asOf: now
        ))
        XCTAssertNil(LocationQualityPolicy.visitCoordinate(
            from: location(latitude: 40.7605, accuracy: 150), near: restaurant, asOf: now
        ))
        XCTAssertNil(LocationQualityPolicy.visitCoordinate(
            from: location(latitude: 40.7605), near: nil, asOf: now
        ))
    }

    func testManualPlaceDoesNotInventCoordinatesWhileMappedVisitUsesRestaurantPin() {
        let manual = store.createLocation(name: "Unmapped Supper Club", category: .fullService)
        let manualVisit = store.logVisit(at: manual, reaction: .liked)
        XCTAssertFalse(manual.hasCoordinates)
        XCTAssertFalse(manualVisit.hasCoordinates)

        let mapped = store.createLocation(
            name: "Mapped Cafe",
            category: .coffeeTea,
            coordinate: (40.7600, -111.8900)
        )
        let mappedVisit = store.logVisit(at: mapped, reaction: .liked)
        XCTAssertTrue(mappedVisit.hasCoordinates)
        XCTAssertEqual(mappedVisit.latitude, mapped.latitude, accuracy: 0.000_001)
        XCTAssertEqual(mappedVisit.longitude, mapped.longitude, accuracy: 0.000_001)
    }

    func testInvalidRestaurantCoordinatesAreDiscardedBeforeDuplicateDetection() {
        let location = store.createLocation(name: "Finite Cafe", category: .coffeeTea)

        store.updateLocationDetails(
            location,
            name: location.name,
            category: location.category,
            cuisines: location.cuisines,
            tags: location.tags,
            address: nil,
            city: nil,
            phone: nil,
            urlString: nil,
            hoursText: nil,
            latitude: .nan,
            longitude: .infinity,
            isClosed: false
        )

        XCTAssertFalse(location.hasCoordinates)
        XCTAssertNil(location.coordinate)
        XCTAssertTrue(store.duplicateLocationSuggestions().isEmpty)
    }

    func testSanitizedBackfillPhotoBoundsStoredPixelDimensions() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 3_000, height: 2_400)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 2_400))
        }
        let data = try XCTUnwrap(source.jpegData(compressionQuality: 0.95))

        let photo = try XCTUnwrap(ImageSanitizer.process(data))
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(photo.fullData as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)

        XCTAssertLessThanOrEqual(max(width, height), 2_048)
    }

    func testChangingVisitLocationMovesAndMergesDishEvidence() throws {
        let source = store.createLocation(name: "Wrong Branch", category: .fullService, coordinate: (40.70, -111.90))
        let destination = store.createLocation(name: "Right Branch", category: .fullService, coordinate: (40.80, -111.80))
        let personID = try XCTUnwrap(store.currentPerson?.id)

        let destinationVisit = store.logVisit(at: destination, reaction: .liked)
        let destinationEntry = try XCTUnwrap(store.addDish(
            name: "House Pasta", role: .entree, reaction: .liked, wouldOrderAgain: true,
            to: destinationVisit, personID: personID
        ))
        let destinationDish = try XCTUnwrap(destinationEntry.dish)

        let correctedVisit = store.logVisit(at: source, reaction: .loved)
        let correctedEntry = try XCTUnwrap(store.addDish(
            name: "house pasta", role: .entree, reaction: .loved, wouldOrderAgain: true,
            to: correctedVisit, personID: personID
        ))

        store.changeLocation(of: correctedVisit, to: destination)

        XCTAssertEqual(correctedVisit.location?.id, destination.id)
        XCTAssertEqual(correctedEntry.dish?.id, destinationDish.id, "Matching destination dishes should be reused")
        XCTAssertEqual(destinationDish.entryArray.count, 2)
        XCTAssertTrue(source.dishArray.isEmpty, "The orphaned dish should not remain on the incorrect restaurant")
        XCTAssertEqual(correctedVisit.latitude, destination.latitude, accuracy: 0.000_001)
        XCTAssertEqual(correctedVisit.longitude, destination.longitude, accuracy: 0.000_001)
        XCTAssertNil(store.score(for: source))
        XCTAssertNotNil(store.score(for: destination))
    }

    func testAddingCircleMemberPromotesTheCanonicalNamedPersonAndPreservesVisitTags() throws {
        let companion = try XCTUnwrap(store.addNamedCompanion(name: "Aunt Jo"))
        let location = store.createLocation(name: "Linked Table")
        let visit = store.logVisit(at: location, reaction: .loved, companionIDs: [companion.id])

        let promoted = try XCTUnwrap(store.addCircleMember(name: " aunt jó "))

        XCTAssertEqual(promoted.id, companion.id)
        XCTAssertTrue(promoted.isCircleMember)
        XCTAssertTrue(store.namedCompanions.isEmpty)
        XCTAssertEqual(store.taggedPeople(for: visit).map(\.id), [promoted.id])
        XCTAssertTrue(store.pendingVisits(for: promoted.id).contains { $0.id == visit.id })
        XCTAssertTrue(store.isSharedVisit(visit))
    }

    func testAddingNamedPersonReusesAnExistingCircleMember() throws {
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })

        let reused = try XCTUnwrap(store.addNamedCompanion(name: "  MICHELLE "))

        XCTAssertEqual(reused.id, michelle.id)
        XCTAssertEqual(store.people.filter { $0.name.localizedCaseInsensitiveCompare("Michelle") == .orderedSame }.count, 1)
    }

    func testDeletingSavedCompanionHidesItFromFutureListsButKeepsPastName() throws {
        let companion = try XCTUnwrap(store.addNamedCompanion(name: "Aunt Jo"))
        let location = store.createLocation(name: "Goodbye Cafe")
        let visit = store.logVisit(at: location, reaction: .liked, companionIDs: [companion.id])

        XCTAssertTrue(store.deleteNamedCompanion(companion.id))
        XCTAssertFalse(store.namedCompanions.contains { $0.id == companion.id })
        XCTAssertEqual(store.person(id: companion.id)?.name, "Aunt Jo")
        XCTAssertTrue(store.person(id: companion.id)?.isArchived == true)
        XCTAssertEqual(store.taggedPeople(for: visit).map(\.name), ["Aunt Jo"])

        XCTAssertTrue(store.updateVisit(
            visit, type: nil, priceBand: 0, occasion: nil, memory: nil,
            companions: [companion.id]
        ))
        XCTAssertEqual(store.taggedPeople(for: visit).map(\.name), ["Aunt Jo"])
    }

    func testDeletedCompanionCanBeAddedAgainAsAFreshProfile() throws {
        let deleted = try XCTUnwrap(store.addNamedCompanion(name: "Aunt Jo"))
        XCTAssertTrue(store.deleteNamedCompanion(deleted.id))

        let replacement = try XCTUnwrap(store.addNamedCompanion(name: " Aunt Jo "))

        XCTAssertNotEqual(replacement.id, deleted.id)
        XCTAssertEqual(store.namedCompanions.map(\.id), [replacement.id])
        XCTAssertFalse(replacement.isArchived)
    }

    func testRenamingAPersonUpdatesEveryLinkedVisitName() throws {
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let visit = store.logVisit(at: store.createLocation(name: "Rename Table"), reaction: .liked, companionIDs: [michelle.id])

        XCTAssertTrue(store.renamePerson(michelle, to: "Mickey"))

        XCTAssertEqual(store.taggedPeople(for: visit).map(\.name), ["Mickey"])
        XCTAssertEqual(store.attendees(for: visit).map(\.name), ["George", "Mickey"])
    }

    func testRenamingACircleTrimsTheNameAndRejectsAnEmptyName() throws {
        let circle = try XCTUnwrap(store.activeCircle)

        XCTAssertTrue(store.renameCircle(circle, to: "  The Supper Club  "))
        XCTAssertEqual(store.activeCircle?.name, "The Supper Club")
        XCTAssertFalse(store.renameCircle(circle, to: "   "))
        XCTAssertEqual(store.activeCircle?.name, "The Supper Club")
    }

    func testReloadReconcilesLegacyMemberGuestDuplicatesAcrossEveryReference() throws {
        let circle = try XCTUnwrap(store.activeCircle)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let legacyGuest = PersonEntity(context: store.context)
        legacyGuest.id = UUID()
        legacyGuest.name = "michelle"
        legacyGuest.isMe = false
        legacyGuest.isCircleMember = false
        legacyGuest.colorHex = "7A7166"
        legacyGuest.createdAt = .now
        legacyGuest.circle = circle
        try persistence.save()

        let first = store.createLocation(name: "Legacy Link One")
        let second = store.createLocation(name: "Legacy Link Two")
        let visit = store.logVisit(at: first, reaction: .loved)
        visit.companionIDs = [legacyGuest.id]
        _ = store.addRating(to: visit, personID: legacyGuest.id, reaction: .liked)
        store.recordComparison(a: first, b: second, outcome: .a, personID: legacyGuest.id)
        store.toggleWant(second, by: legacyGuest.id)
        try persistence.save()

        store.reload()

        let restoredVisit = try XCTUnwrap(store.visits.first { $0.id == visit.id })
        XCTAssertEqual(store.people.filter { $0.name.localizedCaseInsensitiveCompare("Michelle") == .orderedSame }.map(\.id), [michelle.id])
        XCTAssertEqual(restoredVisit.companionIDs, [michelle.id])
        XCTAssertNotNil(restoredVisit.rating(for: michelle.id))
        XCTAssertEqual(store.comparisons.first { !$0.isAnchor }?.personID, michelle.id)
        XCTAssertEqual(store.wantEntries.first?.addedByID, michelle.id)
        XCTAssertTrue(store.isSharedVisit(restoredVisit))
    }

    func testReloadKeepsConcurrentSameNameMembersAsDistinctAccountIdentities() throws {
        let circle = try XCTUnwrap(store.activeCircle)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let concurrentMichelle = PersonEntity(context: store.context)
        concurrentMichelle.id = UUID()
        concurrentMichelle.name = " MICHELLE "
        concurrentMichelle.isMe = false
        concurrentMichelle.isCircleMember = true
        concurrentMichelle.colorHex = "43533D"
        concurrentMichelle.createdAt = michelle.createdAt.addingTimeInterval(1)
        concurrentMichelle.circle = circle
        try persistence.save()

        let location = store.createLocation(name: "Concurrent Table")
        let visit = store.logVisit(at: location, reaction: .loved)
        visit.companionIDs = [michelle.id, concurrentMichelle.id]
        try persistence.save()
        store.reload()

        let editableVisit = try XCTUnwrap(store.visits.first { $0.id == visit.id })
        _ = store.addRating(to: editableVisit, personID: michelle.id, reaction: .fine)
        _ = store.addRating(to: editableVisit, personID: concurrentMichelle.id, reaction: .liked)
        _ = store.addDish(
            name: "Shared Soup", role: .appetizer, reaction: .fine,
            wouldOrderAgain: false, to: editableVisit, personID: michelle.id
        )
        _ = store.addDish(
            name: "Shared Soup", role: .appetizer, reaction: .loved,
            wouldOrderAgain: true, to: editableVisit, personID: concurrentMichelle.id
        )
        try persistence.save()

        store.reload()

        let restoredVisit = try XCTUnwrap(store.visits.first { $0.id == visit.id })
        XCTAssertEqual(Set(store.circleMembers.filter {
            $0.name.trimmingCharacters(in: .whitespaces).localizedCaseInsensitiveCompare("Michelle") == .orderedSame
        }.map(\.id)), Set([michelle.id, concurrentMichelle.id]))
        XCTAssertEqual(Set(restoredVisit.companionIDs), Set([michelle.id, concurrentMichelle.id]))
        XCTAssertEqual(restoredVisit.ratingArray.count, 3, "George and both account identities should retain their own ratings")
        XCTAssertEqual(restoredVisit.rating(for: michelle.id)?.reaction, .fine)
        XCTAssertEqual(restoredVisit.rating(for: concurrentMichelle.id)?.reaction, .liked)
        XCTAssertEqual(restoredVisit.dishEntryArray.filter { $0.personID == michelle.id }.count, 1)
        XCTAssertEqual(restoredVisit.dishEntryArray.filter { $0.personID == concurrentMichelle.id }.count, 1)
        XCTAssertTrue(store.isSharedVisit(restoredVisit))
    }

    func testSettleQuestionsDoNotRepeatAnUnchangedAnsweredPairAfterReload() {
        let first = store.createLocation(name: "Settled First", category: .fullService)
        let second = store.createLocation(name: "Settled Second", category: .fullService)
        _ = store.logVisit(at: first, reaction: .loved)
        _ = store.logVisit(at: second, reaction: .liked)
        let pairIDs = Set([first.id, second.id])

        XCTAssertTrue(store.settleQuestions().contains { Set([$0.a.id, $0.b.id]) == pairIDs })
        store.recordComparison(a: second, b: first, outcome: .b)
        store.reload()

        XCTAssertFalse(store.settleQuestions().contains { Set([$0.a.id, $0.b.id]) == pairIDs })
    }

    func testSettleScorePromptCountIncludesScoreCheckWhenPairQueueIsEmpty() {
        let first = store.createLocation(name: "Settled First", category: .fullService)
        let second = store.createLocation(name: "Settled Second", category: .fullService)
        _ = store.logVisit(at: first, reaction: .loved)
        _ = store.logVisit(at: second, reaction: .liked)
        store.recordComparison(a: first, b: second, outcome: .a)

        XCTAssertTrue(store.settleQuestions().isEmpty)
        XCTAssertEqual(store.settleScorePrompts().count, 1)
    }

    func testSettleScorePromptsStopAfterTheRemainingScoreCheckIsAnswered() throws {
        let first = store.createLocation(name: "Finished First", category: .fullService)
        let second = store.createLocation(name: "Finished Second", category: .fullService)
        _ = store.logVisit(at: first, reaction: .loved)
        _ = store.logVisit(at: second, reaction: .liked)
        store.recordComparison(a: first, b: second, outcome: .a)

        let anchorLocation = try XCTUnwrap(store.settleScorePrompts().compactMap { prompt in
            if case .anchor(let location) = prompt { return location }
            return nil
        }.first)
        store.recordAnchor(for: anchorLocation, value: 85)

        XCTAssertTrue(store.settleScorePrompts().isEmpty, "An unchanged answered score check must leave the queue complete")
        store.reload()
        XCTAssertTrue(store.settleScorePrompts().isEmpty, "Completion must survive persistence and reload")
    }

    func testSettleScoreQueueDrainsAfterAnsweringEveryOfferedPrompt() {
        for index in 0..<8 {
            let location = store.createLocation(name: "Drain Place \(index)", category: .fullService)
            _ = store.logVisit(at: location, reaction: .liked)
        }

        var rounds = 0
        while rounds < 10 {
            let prompts = store.settleScorePrompts()
            guard !prompts.isEmpty else { break }
            for prompt in prompts {
                switch prompt {
                case .comparison(let question):
                    store.recordComparison(a: question.a, b: question.b, outcome: .a)
                case .anchor(let location):
                    store.recordAnchor(for: location, value: 75)
                }
            }
            rounds += 1
        }

        XCTAssertTrue(store.settleScorePrompts().isEmpty, "Answering every offered prompt must converge to an empty queue")
    }

    func testSettleScoreSupportsSuccessiveBoundedRounds() {
        for index in 0..<12 {
            let location = store.createLocation(name: "Round Place \(index)", category: .fullService)
            _ = store.logVisit(at: location, reaction: .liked)
        }

        func answer(_ prompts: [SettleScorePrompt]) {
            for prompt in prompts {
                switch prompt {
                case .comparison(let question):
                    store.recordComparison(a: question.a, b: question.b, outcome: .a)
                case .anchor(let location):
                    store.recordAnchor(for: location, value: 75)
                }
            }
        }

        let firstRound = store.settleScorePrompts(limit: 5)
        XCTAssertEqual(firstRound.count, 5, "A full round should stop at five prompts")
        answer(firstRound)

        let secondRound = store.settleScorePrompts(limit: 5)
        XCTAssertFalse(secondRound.isEmpty, "Answering one round should leave another round available")
        XCTAssertLessThanOrEqual(secondRound.count, 5)
        answer(secondRound)

        var additionalRounds = 0
        while additionalRounds < 20 {
            let prompts = store.settleScorePrompts(limit: 5)
            guard !prompts.isEmpty else { break }
            XCTAssertLessThanOrEqual(prompts.count, 5)
            answer(prompts)
            additionalRounds += 1
        }

        XCTAssertTrue(store.settleScorePrompts().isEmpty, "Successive short rounds must still converge to an empty queue")
    }

    func testSettleScorePromptsReofferTheScoreCheckOnlyAfterItsRankingEvidenceChanges() throws {
        let first = store.createLocation(name: "Living First", category: .fullService)
        let second = store.createLocation(name: "Living Second", category: .fullService)
        _ = store.logVisit(at: first, reaction: .loved)
        _ = store.logVisit(at: second, reaction: .liked)
        store.recordComparison(a: first, b: second, outcome: .a)

        let anchorLocation = try XCTUnwrap(store.settleScorePrompts().compactMap { prompt in
            if case .anchor(let location) = prompt { return location }
            return nil
        }.first)
        store.recordAnchor(for: anchorLocation, value: 85)
        store.updateLocation(
            anchorLocation,
            name: "\(anchorLocation.name) Renamed",
            category: anchorLocation.category,
            cuisines: ["Updated cuisine"],
            tags: ["Updated tag"],
            isClosed: false
        )
        XCTAssertTrue(store.settleScorePrompts().isEmpty, "Metadata that does not affect ranking evidence must not reopen a score check")

        let personID = try XCTUnwrap(store.currentPerson?.id)
        let rating = try XCTUnwrap(anchorLocation.visitArray.compactMap { $0.rating(for: personID) }.first)
        store.updateRating(rating, reaction: .notForMe)

        let reopenedAnchorIDs = store.settleScorePrompts().compactMap { prompt -> UUID? in
            if case .anchor(let location) = prompt { return location.id }
            return nil
        }
        XCTAssertEqual(reopenedAnchorIDs, [anchorLocation.id], "Changed rating evidence should reopen the score check it made stale")
    }

    func testAnsweredScoreCheckDoesNotConsumeAComparisonSlot() throws {
        var locations: [RestaurantLocation] = []
        for index in 0..<7 {
            let location = store.createLocation(name: "Queue Place \(index)", category: .fullService)
            _ = store.logVisit(at: location, reaction: .liked)
            locations.append(location)
        }
        store.recordAnchor(for: locations[0], value: 75)

        let prompts = store.settleScorePrompts(limit: 5)
        let comparisonCount = prompts.reduce(into: 0) { count, prompt in
            if case .comparison = prompt { count += 1 }
        }
        let anchorCount = prompts.reduce(into: 0) { count, prompt in
            if case .anchor = prompt { count += 1 }
        }

        XCTAssertEqual(comparisonCount, 5)
        XCTAssertEqual(anchorCount, 0)
    }

    func testScoreCheckCompletionIsScopedToTheSelectedPerson() throws {
        let me = try XCTUnwrap(store.currentPerson)
        let otherMember = try XCTUnwrap(store.circleMembers.first { $0.id != me.id })
        let first = store.createLocation(name: "Scoped First", category: .fullService)
        let second = store.createLocation(name: "Scoped Second", category: .fullService)
        let firstVisit = store.logVisit(
            at: first, reaction: .loved, personID: me.id, companionIDs: [otherMember.id]
        )
        let secondVisit = store.logVisit(
            at: second, reaction: .liked, personID: me.id, companionIDs: [otherMember.id]
        )
        _ = store.addRating(to: firstVisit, personID: otherMember.id, reaction: .liked)
        _ = store.addRating(to: secondVisit, personID: otherMember.id, reaction: .fine)
        store.recordComparison(a: first, b: second, outcome: .a, personID: me.id)
        store.recordComparison(a: first, b: second, outcome: .a, personID: otherMember.id)

        let myAnchorLocation = try XCTUnwrap(store.settleScorePrompts(personID: me.id).compactMap { prompt in
            if case .anchor(let location) = prompt { return location }
            return nil
        }.first)
        store.recordAnchor(for: myAnchorLocation, value: 85, personID: me.id)

        XCTAssertTrue(store.settleScorePrompts(personID: me.id).isEmpty)
        XCTAssertTrue(store.settleScorePrompts(personID: otherMember.id).contains { prompt in
            if case .anchor = prompt { return true }
            return false
        }, "One person's score check must not settle another person's queue")
    }

    func testReloadBackfillsLegacyScoreCheckFingerprintsWithoutReopeningIt() throws {
        let first = store.createLocation(name: "Legacy Anchor First", category: .fullService)
        let second = store.createLocation(name: "Legacy Anchor Second", category: .fullService)
        _ = store.logVisit(at: first, reaction: .loved)
        _ = store.logVisit(at: second, reaction: .liked)
        store.recordComparison(a: first, b: second, outcome: .a)
        store.recordAnchor(for: first, value: 85)
        let anchor = try XCTUnwrap(store.comparisons.first(where: \.isAnchor))
        anchor.locationAEvidenceFingerprint = ""
        anchor.locationBEvidenceFingerprint = ""
        try persistence.save()

        store.reload()

        let restoredAnchor = try XCTUnwrap(store.comparisons.first(where: \.isAnchor))
        XCTAssertFalse(restoredAnchor.locationAEvidenceFingerprint.isEmpty)
        XCTAssertEqual(restoredAnchor.locationBEvidenceFingerprint, restoredAnchor.locationAEvidenceFingerprint)
        XCTAssertTrue(store.settleScorePrompts().isEmpty)
    }

    func testSettleQuestionsUseOnlyTheSelectedPersonsComparisonHistory() throws {
        let me = try XCTUnwrap(store.currentPerson)
        let otherMember = try XCTUnwrap(store.circleMembers.first { $0.id != me.id })
        let first = store.createLocation(name: "Personal First", category: .fullService)
        let second = store.createLocation(name: "Personal Second", category: .fullService)
        for _ in 0..<2 {
            _ = store.logVisit(at: first, reaction: .loved, personID: me.id)
            _ = store.logVisit(at: second, reaction: .liked, personID: me.id)
        }
        let pairIDs = Set([first.id, second.id])
        store.recordComparison(a: first, b: second, outcome: .a, personID: otherMember.id)

        XCTAssertTrue(
            store.settleQuestions(personID: me.id).contains { Set([$0.a.id, $0.b.id]) == pairIDs },
            "Another member's answer must not suppress this person's matchup"
        )
    }

    func testSettleQuestionsReofferAnAnsweredPairAfterANewRatedVisit() {
        let first = store.createLocation(name: "Revisit First", category: .fullService)
        let second = store.createLocation(name: "Revisit Second", category: .fullService)
        _ = store.logVisit(at: first, reaction: .loved)
        _ = store.logVisit(at: second, reaction: .liked)
        let pairIDs = Set([first.id, second.id])
        store.recordComparison(a: first, b: second, outcome: .a)
        XCTAssertFalse(store.settleQuestions().contains { Set([$0.a.id, $0.b.id]) == pairIDs })

        _ = store.logVisit(at: second, reaction: .notForMe)

        XCTAssertTrue(store.settleQuestions().contains { Set([$0.a.id, $0.b.id]) == pairIDs })
        store.recordComparison(a: second, b: first, outcome: .b)
        XCTAssertFalse(store.settleQuestions().contains { Set([$0.a.id, $0.b.id]) == pairIDs })
    }

    func testSettleQuestionsReofferAnAnsweredPairAfterRatingEvidenceIsEdited() throws {
        let first = store.createLocation(name: "Edited First", category: .fullService)
        let second = store.createLocation(name: "Edited Second", category: .fullService)
        let visit = store.logVisit(at: first, reaction: .loved)
        _ = store.logVisit(at: second, reaction: .liked)
        let pairIDs = Set([first.id, second.id])
        store.recordComparison(a: first, b: second, outcome: .a)
        XCTAssertFalse(store.settleQuestions().contains { Set([$0.a.id, $0.b.id]) == pairIDs })

        store.updateRating(try XCTUnwrap(visit.rating(for: try XCTUnwrap(store.currentPerson?.id))), reaction: .fine)

        XCTAssertTrue(store.settleQuestions().contains { Set([$0.a.id, $0.b.id]) == pairIDs })
    }

    func testSettleQuestionsIgnoreMetadataEditsButReofferAfterDishEvidenceChanges() throws {
        let personID = try XCTUnwrap(store.currentPerson?.id)
        let first = store.createLocation(name: "Dish First", category: .fullService)
        let second = store.createLocation(name: "Dish Second", category: .fullService)
        let firstVisit = store.logVisit(at: first, reaction: .liked)
        _ = store.logVisit(at: second, reaction: .liked)
        let pairIDs = Set([first.id, second.id])
        store.recordComparison(a: first, b: second, outcome: .tie)

        store.updateLocationDetails(
            first, name: "Dish First Renamed", category: .fullService, cuisines: ["Italian"], tags: ["Patio"],
            address: "1 Main St", city: "Salt Lake City", phone: nil, urlString: nil, hoursText: nil,
            latitude: nil, longitude: nil, isClosed: false
        )
        XCTAssertFalse(store.settleQuestions().contains { Set([$0.a.id, $0.b.id]) == pairIDs })

        _ = store.addDish(
            name: "New Pasta", role: .entree, reaction: .loved, wouldOrderAgain: true,
            to: firstVisit, personID: personID
        )

        XCTAssertTrue(store.settleQuestions().contains { Set([$0.a.id, $0.b.id]) == pairIDs })
    }

    func testSettleQuestionsReofferAfterRatedVisitEvidenceIsDeleted() {
        let first = store.createLocation(name: "Delete Evidence First", category: .fullService)
        let second = store.createLocation(name: "Delete Evidence Second", category: .fullService)
        let visitToDelete = store.logVisit(at: first, reaction: .loved)
        _ = store.logVisit(at: first, reaction: .liked)
        _ = store.logVisit(at: second, reaction: .liked)
        let pairIDs = Set([first.id, second.id])
        store.recordComparison(a: first, b: second, outcome: .a)
        XCTAssertFalse(store.settleQuestions().contains { Set([$0.a.id, $0.b.id]) == pairIDs })

        store.deleteVisit(visitToDelete)

        XCTAssertTrue(store.settleQuestions().contains { Set([$0.a.id, $0.b.id]) == pairIDs })
    }

    func testSettleQuestionsReofferAfterARatedVisitDateChanges() {
        let first = store.createLocation(name: "Date Evidence First", category: .fullService)
        let second = store.createLocation(name: "Date Evidence Second", category: .fullService)
        let visit = store.logVisit(at: first, reaction: .loved)
        _ = store.logVisit(at: second, reaction: .liked)
        let pairIDs = Set([first.id, second.id])
        store.recordComparison(a: first, b: second, outcome: .a)
        let captureDate = Date.now.addingTimeInterval(-90 * 86_400)

        store.updateVisitDateFromPhotoMetadata(visit, photos: [
            BackfillPhoto(
                id: UUID(), fullData: Data([0x01]), thumbnailData: nil,
                date: captureDate, coordinate: nil, captureDate: captureDate
            )
        ])

        XCTAssertTrue(store.settleQuestions().contains { Set([$0.a.id, $0.b.id]) == pairIDs })
    }

    func testSettleQuestionsIgnoreUnratedVisitsAndAnotherPersonsRatings() throws {
        let me = try XCTUnwrap(store.currentPerson)
        let otherMember = try XCTUnwrap(store.circleMembers.first { $0.id != me.id })
        let first = store.createLocation(name: "Private Evidence First", category: .fullService)
        let second = store.createLocation(name: "Private Evidence Second", category: .fullService)
        _ = store.logVisit(at: first, reaction: .loved, personID: me.id)
        _ = store.logVisit(at: second, reaction: .liked, personID: me.id)
        let pairIDs = Set([first.id, second.id])
        store.recordComparison(a: first, b: second, outcome: .a, personID: me.id)

        let unratedVisit = store.logVisit(at: first, reaction: nil, personID: me.id)
        _ = store.addRating(to: unratedVisit, personID: otherMember.id, reaction: .notForMe)

        XCTAssertFalse(
            store.settleQuestions(personID: me.id).contains { Set([$0.a.id, $0.b.id]) == pairIDs }
        )
    }

    func testManualDirectComparisonsCanStillBeRepeated() {
        let first = store.createLocation(name: "Manual First", category: .fullService)
        let second = store.createLocation(name: "Manual Second", category: .fullService)

        store.recordComparison(a: first, b: second, outcome: .a)
        store.recordComparison(a: second, b: first, outcome: .b)

        XCTAssertEqual(store.comparisons.filter { !$0.isAnchor }.count, 2)
    }

    func testComparisonOwnerCanModifyAndUndoAnswerWithoutAddingEvidence() throws {
        let first = store.createLocation(name: "Editable First", category: .fullService)
        let second = store.createLocation(name: "Editable Second", category: .fullService)
        _ = store.logVisit(at: first, reaction: .loved)
        _ = store.logVisit(at: second, reaction: .liked)
        let comparisonID = try XCTUnwrap(store.recordComparison(a: first, b: second, outcome: .a))
        let comparisonCount = store.comparisons.count
        let originalScores = Dictionary(uniqueKeysWithValues: store.ranked().map { ($0.id, $0.score) })

        XCTAssertTrue(store.updateComparison(id: comparisonID, outcome: .b))
        XCTAssertEqual(store.comparisons.count, comparisonCount)
        XCTAssertEqual(store.comparisons.first(where: { $0.id == comparisonID })?.outcome, .b)
        let revisedScores = Dictionary(uniqueKeysWithValues: store.ranked().map { ($0.id, $0.score) })
        XCTAssertLessThan(try XCTUnwrap(revisedScores[first.id]), try XCTUnwrap(originalScores[first.id]))
        XCTAssertGreaterThan(try XCTUnwrap(revisedScores[second.id]), try XCTUnwrap(originalScores[second.id]))

        XCTAssertTrue(store.removeComparison(id: comparisonID))
        XCTAssertFalse(store.comparisons.contains(where: { $0.id == comparisonID }))
    }

    func testAnotherPersonCannotModifyOrUndoComparison() throws {
        let me = try XCTUnwrap(store.currentPerson)
        let otherMember = try XCTUnwrap(store.circleMembers.first { $0.id != me.id })
        let first = store.createLocation(name: "Private First", category: .fullService)
        let second = store.createLocation(name: "Private Second", category: .fullService)
        let comparisonID = try XCTUnwrap(
            store.recordComparison(a: first, b: second, outcome: .a, personID: otherMember.id)
        )

        XCTAssertFalse(store.updateComparison(id: comparisonID, outcome: .b))
        XCTAssertFalse(store.removeComparison(id: comparisonID))
        XCTAssertEqual(store.comparisons.first(where: { $0.id == comparisonID })?.outcome, .a)
    }

    func testMergeReassignsComparisonEvidence() {
        let keeper = store.createLocation(name: "The Keeper", category: .bakeries)
        let duplicate = store.createLocation(name: "Keeper Bakery", category: .bakeries)
        let duplicateID = duplicate.id
        let other = store.createLocation(name: "The Other", category: .bakeries)
        let personID = try! XCTUnwrap(store.currentPerson?.id)
        let keeperVisit = store.logVisit(at: keeper, reaction: .liked)
        let duplicateVisit = store.logVisit(at: duplicate, reaction: .loved)
        _ = store.logVisit(at: other, reaction: .liked)
        let keeperDish = try! XCTUnwrap(store.addDish(
            name: "Croissant", role: .entree, reaction: .liked, wouldOrderAgain: true,
            to: keeperVisit, personID: personID
        )?.dish)
        let duplicateEntry = try! XCTUnwrap(store.addDish(
            name: "croissant", role: .entree, reaction: .loved, wouldOrderAgain: true,
            to: duplicateVisit, personID: personID
        ))
        store.toggleWant(duplicate)
        store.recordComparison(a: duplicate, b: other, outcome: .a)
        store.recordComparison(a: keeper, b: duplicate, outcome: .a)
        XCTAssertTrue(store.ranked().contains { $0.id == duplicateID }, "Prime the score cache with the soon-to-be-deleted location")

        store.merge(duplicate, into: keeper)

        XCTAssertTrue(store.comparisons.contains { $0.locationAID == keeper.id && $0.locationBID == other.id })
        XCTAssertFalse(store.comparisons.contains { $0.locationAID == duplicateID || $0.locationBID == duplicateID })
        XCTAssertFalse(store.comparisons.contains { $0.locationAID == $0.locationBID && !$0.isAnchor })
        XCTAssertFalse(store.locations.contains { $0.id == duplicateID })
        XCTAssertFalse(store.ranked().contains { $0.id == duplicateID })
        XCTAssertEqual(keeper.visitArray.count, 2)
        XCTAssertEqual(store.wantEntries.first?.location?.id, keeper.id)
        XCTAssertEqual(duplicateEntry.dish?.id, keeperDish.id)
        XCTAssertNil(duplicate.managedObjectContext)
    }

    func testDeletingVisitRemovesCascadeChildrenAndOrphanedDishes() throws {
        let personID = try XCTUnwrap(store.currentPerson?.id)
        let location = store.createLocation(name: "Delete Safely", category: .fullService)
        let locationID = location.id
        let visit = store.logVisit(at: location, reaction: .loved)
        let visitID = visit.id
        _ = try XCTUnwrap(store.addDish(
            name: "Last Dish", role: .entree, reaction: .loved, wouldOrderAgain: true,
            to: visit, personID: personID
        ))
        store.addPhoto(fullData: Data([0x01]), thumbnailData: Data([0x02]), to: visit)
        XCTAssertTrue(store.ranked().contains { $0.id == locationID }, "Prime rankings before deleting their visit evidence")

        store.deleteVisit(id: visitID)

        XCTAssertFalse(store.visits.contains { $0.id == visitID })
        XCTAssertTrue(store.locations.contains { $0.id == locationID })
        XCTAssertTrue(location.visitArray.isEmpty)
        XCTAssertTrue(location.dishArray.isEmpty)
        XCTAssertFalse(store.ranked().contains { $0.id == locationID })
        for entityName in ["VisitEntity", "VisitParticipantEntity", "RatingEntity", "DishEntity", "DishEntryEntity", "PhotoEntity"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            XCTAssertEqual(try store.context.count(for: request), 0, "Expected \(entityName) to be removed with the visit")
        }
    }

    func testDeletingEmptyRestaurantRemovesRestaurantAndAllDependentEvidence() throws {
        let me = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.id != me.id })
        let restaurant = store.createLocation(name: "Empty Restaurant", category: .fullService)
        let restaurantID = restaurant.id
        let other = store.createLocation(name: "Still Here", category: .fullService)
        _ = store.logVisit(at: other, reaction: .liked, personID: me.id)
        store.recordComparison(a: restaurant, b: other, outcome: .a, personID: me.id)
        store.recordComparison(a: other, b: restaurant, outcome: .b, personID: michelle.id)
        store.recordAnchor(for: restaurant, value: 90, personID: me.id)
        store.toggleWant(restaurant, by: me.id)
        XCTAssertTrue(store.ranked(for: me.id).contains { $0.id == restaurantID })

        XCTAssertTrue(store.deleteRestaurant(id: restaurantID))

        XCTAssertFalse(store.locations.contains { $0.id == restaurantID })
        XCTAssertFalse(store.comparisons.contains {
            $0.locationAID == restaurantID || $0.locationBID == restaurantID
        })
        XCTAssertFalse(store.wantEntries.contains { $0.location?.id == restaurantID })
        XCTAssertFalse(store.ranked(for: me.id).contains { $0.id == restaurantID })
        XCTAssertTrue(store.locations.contains { $0.id == other.id })
        XCTAssertNil(restaurant.managedObjectContext)
    }

    func testRestaurantWithAnOutingCannotBeDeleted() {
        let restaurant = store.createLocation(name: "Has History", category: .fullService)
        let visit = store.logVisit(at: restaurant, reaction: .liked)

        XCTAssertFalse(store.deleteRestaurant(id: restaurant.id))

        XCTAssertTrue(store.locations.contains { $0.id == restaurant.id })
        XCTAssertTrue(store.visits.contains { $0.id == visit.id })
    }

    func testDeletingFinalOutingCanAlsoRemoveRestaurantAndDependentComparisons() throws {
        let me = try XCTUnwrap(store.currentPerson)
        let restaurant = store.createLocation(name: "Last Outing", category: .fullService)
        let restaurantID = restaurant.id
        let visit = store.logVisit(at: restaurant, reaction: .loved, personID: me.id)
        let visitID = visit.id
        let other = store.createLocation(name: "Comparison Survivor", category: .fullService)
        _ = store.logVisit(at: other, reaction: .liked, personID: me.id)
        store.recordComparison(a: restaurant, b: other, outcome: .a, personID: me.id)

        XCTAssertTrue(store.deleteVisit(id: visitID, removingRestaurantIfEmpty: true))

        XCTAssertFalse(store.visits.contains { $0.id == visitID })
        XCTAssertFalse(store.locations.contains { $0.id == restaurantID })
        XCTAssertFalse(store.comparisons.contains {
            $0.locationAID == restaurantID || $0.locationBID == restaurantID
        })
        XCTAssertTrue(store.locations.contains { $0.id == other.id })
        XCTAssertNil(restaurant.managedObjectContext)
    }

    func testDeletingOneOfMultipleOutingsCannotRemoveRestaurant() {
        let restaurant = store.createLocation(name: "Two Outings", category: .fullService)
        let firstVisit = store.logVisit(at: restaurant, reaction: .liked)
        let secondVisit = store.logVisit(at: restaurant, reaction: .loved)
        let firstVisitID = firstVisit.id
        let secondVisitID = secondVisit.id

        XCTAssertTrue(store.deleteVisit(id: firstVisitID, removingRestaurantIfEmpty: true))

        XCTAssertTrue(store.locations.contains { $0.id == restaurant.id })
        XCTAssertFalse(store.visits.contains { $0.id == firstVisitID })
        XCTAssertTrue(store.visits.contains { $0.id == secondVisitID })
        XCTAssertEqual(restaurant.visitArray.map(\.id), [secondVisitID])
    }

    func testDeviceIdentityCanSelectAnotherCircleMember() {
        let michelle = try! XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        store.selectCurrentPerson(michelle.id)
        XCTAssertEqual(store.currentPerson?.id, michelle.id)
        XCTAssertEqual(store.otherCircleMembers.map(\.name), ["George"])
    }

    func testTaggedVisitBehavesTheSameWhenAnotherMemberUsesTheCircle() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let visit = store.logVisit(
            at: store.createLocation(name: "Shared Supper"),
            reaction: .loved,
            companionIDs: [michelle.id]
        )

        XCTAssertTrue(store.pendingVisits(for: george.id).isEmpty)
        XCTAssertEqual(store.attendees(for: visit).map(\.name), ["George", "Michelle"])

        store.selectCurrentPerson(michelle.id)

        XCTAssertEqual(store.pendingVisits().map(\.id), [visit.id])
        XCTAssertEqual(store.attendees(for: visit).map(\.name), ["George", "Michelle"])
        _ = store.addRating(to: visit, personID: michelle.id, reaction: .liked)
        XCTAssertTrue(store.pendingVisits().isEmpty)
    }

    func testMutuallyTaggedIndependentLogsReconcileIntoOneOuting() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let location = store.createLocation(name: "One Real Dinner", category: .fullService)
        let dinnerTime = Date(timeIntervalSince1970: 1_720_000_000)

        _ = store.logVisit(
            at: location,
            reaction: .loved,
            personID: george.id,
            date: dinnerTime,
            companionIDs: [michelle.id]
        )
        let michelleVisit = store.logVisit(
            at: location,
            reaction: .liked,
            personID: michelle.id,
            date: dinnerTime.addingTimeInterval(5 * 60),
            companionIDs: [george.id]
        )
        store.updateMemory("Michelle remembered dessert.", for: michelleVisit, personID: michelle.id)

        store.reload()

        XCTAssertEqual(store.visits.count, 1)
        let outing = try XCTUnwrap(store.visits.first)
        XCTAssertEqual(Set(store.attendees(for: outing).map(\.id)), Set([george.id, michelle.id]))
        XCTAssertEqual(Set(outing.ratingArray.map(\.personID)), Set([george.id, michelle.id]))
        XCTAssertTrue(store.pendingVisits(for: george.id).isEmpty)
        XCTAssertTrue(store.pendingVisits(for: michelle.id).isEmpty)
        XCTAssertNil(store.memory(for: outing, personID: george.id))
        XCTAssertEqual(store.memory(for: outing, personID: michelle.id), "Michelle remembered dessert.")
        XCTAssertEqual(store.score(for: location, personID: george.id)?.ratedVisitCount, 1)
        XCTAssertEqual(store.score(for: location, personID: michelle.id)?.ratedVisitCount, 1)
    }

    func testMutuallyTaggedOutingMergePreservesCoonReactionFromDuplicate() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let location = store.createLocation(name: "Sticker Reunion", category: .fullService)
        let dinnerTime = Date(timeIntervalSince1970: 1_720_000_000)

        let keeper = store.logVisit(
            at: location,
            reaction: .loved,
            personID: george.id,
            date: dinnerTime,
            companionIDs: [michelle.id]
        )
        let duplicate = store.logVisit(
            at: location,
            reaction: .liked,
            personID: michelle.id,
            date: dinnerTime.addingTimeInterval(5 * 60),
            companionIDs: [george.id]
        )
        XCTAssertTrue(store.setCoonReaction(.runItBack, to: michelle.id, in: duplicate))

        store.reload()

        XCTAssertEqual(store.visits.map(\.id), [keeper.id])
        let reaction = try XCTUnwrap(store.myCoonReaction(to: michelle.id, in: keeper))
        XCTAssertEqual(reaction.kind, .runItBack)
        XCTAssertEqual(reaction.authorPersonID, george.id)
        XCTAssertEqual(reaction.targetPersonID, michelle.id)
        XCTAssertEqual(reaction.visit?.id, keeper.id)
    }

    func testMutuallyTaggedOutingMergeKeepsNewestCoonReactionPerPair() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let location = store.createLocation(name: "Sticker Collision", category: .fullService)
        let dinnerTime = Date(timeIntervalSince1970: 1_720_000_000)

        let keeper = store.logVisit(
            at: location,
            reaction: .loved,
            personID: george.id,
            date: dinnerTime,
            companionIDs: [michelle.id]
        )
        _ = store.addRating(to: keeper, personID: michelle.id, reaction: .fine)
        XCTAssertTrue(store.setCoonReaction(.runItBack, to: michelle.id, in: keeper))

        let duplicate = store.logVisit(
            at: location,
            reaction: .liked,
            personID: michelle.id,
            date: dinnerTime.addingTimeInterval(5 * 60),
            companionIDs: [george.id]
        )
        XCTAssertTrue(store.setCoonReaction(.noNotes, to: michelle.id, in: duplicate))

        store.reload()

        XCTAssertEqual(store.coonReactions(to: michelle.id, in: keeper).count, 1)
        XCTAssertEqual(store.myCoonReaction(to: michelle.id, in: keeper)?.kind, .noNotes)
    }

    func testDecliningTaggedOutingClearsPromptWithoutRemovingAttendee() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let visit = store.logVisit(
            at: store.createLocation(name: "No Rating Needed"),
            reaction: .liked,
            personID: george.id,
            companionIDs: [michelle.id]
        )

        XCTAssertEqual(store.pendingVisits(for: michelle.id).map(\.id), [visit.id])

        store.declineRating(for: visit, personID: michelle.id)

        XCTAssertTrue(store.pendingVisits(for: michelle.id).isEmpty)
        XCTAssertEqual(Set(store.attendees(for: visit).map(\.id)), Set([george.id, michelle.id]))
        XCTAssertNil(visit.rating(for: michelle.id))
    }

    func testEntryResponseIsNeededOnlyWhileParticipantIsPending() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let restaurant = store.createLocation(name: "Response Table")
        let declined = store.logVisit(
            at: restaurant, reaction: .liked, personID: george.id, companionIDs: [michelle.id]
        )

        XCTAssertTrue(store.needsEntryResponse(for: declined, personID: michelle.id))
        store.declineRating(for: declined, personID: michelle.id)
        XCTAssertFalse(store.needsEntryResponse(for: declined, personID: michelle.id))

        let contributed = store.logVisit(
            at: restaurant, reaction: .fine, personID: george.id, companionIDs: [michelle.id]
        )
        store.addPhoto(fullData: Data([0x01]), thumbnailData: nil, to: contributed, personID: michelle.id)
        XCTAssertFalse(store.needsEntryResponse(for: contributed, personID: michelle.id))
    }

    func testRejectingIncorrectTagClearsPromptAndRemovesAttendee() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let visit = store.logVisit(
            at: store.createLocation(name: "Wrong Tag"),
            reaction: .liked,
            personID: george.id,
            companionIDs: [michelle.id]
        )

        store.markNotPresent(for: visit, personID: michelle.id)

        XCTAssertTrue(store.pendingVisits(for: michelle.id).isEmpty)
        XCTAssertEqual(store.attendees(for: visit).map(\.id), [george.id])
        XCTAssertFalse(store.isSharedVisit(visit))
    }

    func testReloadReconcilesConcurrentMapRestaurantAndOutingRecords() throws {
        let circle = try XCTUnwrap(store.activeCircle)
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let first = store.createLocation(
            name: "Convergent Cafe",
            address: "10 Main Street",
            sourceIdentifier: "maps-convergent-cafe"
        )
        let concurrent = RestaurantLocation(context: store.context)
        concurrent.id = UUID()
        concurrent.name = first.name
        concurrent.category = first.category
        concurrent.address = first.address
        concurrent.sourceIdentifier = first.sourceIdentifier
        concurrent.createdAt = first.createdAt.addingTimeInterval(1)
        concurrent.updatedAt = concurrent.createdAt
        concurrent.circle = circle
        try persistence.save()

        let dinnerTime = Date(timeIntervalSince1970: 1_720_000_000)
        _ = store.logVisit(
            at: first, reaction: .loved, personID: george.id,
            date: dinnerTime, companionIDs: [michelle.id]
        )
        _ = store.logVisit(
            at: concurrent, reaction: .liked, personID: michelle.id,
            date: dinnerTime, companionIDs: [george.id]
        )

        store.reload()

        XCTAssertEqual(store.locations.filter { $0.sourceIdentifier == "maps-convergent-cafe" }.count, 1)
        XCTAssertEqual(store.visits.count, 1)
        XCTAssertEqual(Set(store.visits.first?.ratingArray.map(\.personID) ?? []), Set([george.id, michelle.id]))
    }

    func testReloadReconcilesMutuallyTaggedManualRestaurantRecords() throws {
        let circle = try XCTUnwrap(store.activeCircle)
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let first = store.createLocation(name: "Neighborhood Supper")
        let concurrent = RestaurantLocation(context: store.context)
        concurrent.id = UUID()
        concurrent.name = " neighborhood supper "
        concurrent.category = .fullService
        concurrent.createdAt = first.createdAt.addingTimeInterval(1)
        concurrent.updatedAt = concurrent.createdAt
        concurrent.circle = circle
        try persistence.save()

        let dinnerTime = Date(timeIntervalSince1970: 1_720_000_000)
        _ = store.logVisit(
            at: first, reaction: .loved, personID: george.id,
            date: dinnerTime, companionIDs: [michelle.id]
        )
        _ = store.logVisit(
            at: concurrent, reaction: .liked, personID: michelle.id,
            date: dinnerTime.addingTimeInterval(5 * 60 * 60), companionIDs: [george.id]
        )

        store.reload()

        XCTAssertEqual(store.locations.filter {
            $0.name.trimmingCharacters(in: .whitespaces).localizedCaseInsensitiveCompare("Neighborhood Supper") == .orderedSame
        }.count, 1)
        XCTAssertEqual(store.visits.count, 1)
        XCTAssertEqual(Set(store.visits.first?.ratingArray.map(\.personID) ?? []), Set([george.id, michelle.id]))
    }

    func testReconciliationKeepsTwoSameDayMutualOutingsSeparate() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let location = store.createLocation(name: "Lunch and Dinner")
        let lunch = Date(timeIntervalSince1970: 1_720_000_000)
        let dinner = lunch.addingTimeInterval(7 * 60 * 60)

        _ = store.logVisit(
            at: location, reaction: .loved, personID: george.id,
            date: lunch, companionIDs: [michelle.id]
        )
        _ = store.logVisit(
            at: location, reaction: .liked, personID: michelle.id,
            date: lunch.addingTimeInterval(5 * 60), companionIDs: [george.id]
        )
        _ = store.logVisit(
            at: location, reaction: .fine, personID: george.id,
            date: dinner, companionIDs: [michelle.id]
        )
        _ = store.logVisit(
            at: location, reaction: .notForMe, personID: michelle.id,
            date: dinner.addingTimeInterval(5 * 60), companionIDs: [george.id]
        )

        store.reload()

        XCTAssertEqual(store.visits.count, 2)
        XCTAssertTrue(store.visits.allSatisfy { $0.ratingArray.count == 2 })
        let ordered = store.visits.sorted { $0.date < $1.date }
        XCTAssertEqual(ordered.first?.rating(for: george.id)?.reaction, .loved)
        XCTAssertEqual(ordered.first?.rating(for: michelle.id)?.reaction, .liked)
        XCTAssertEqual(ordered.last?.rating(for: george.id)?.reaction, .fine)
        XCTAssertEqual(ordered.last?.rating(for: michelle.id)?.reaction, .notForMe)
    }

    func testReloadReconcilesConcurrentSameNamedDishRecordsWithoutCombiningDiners() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let location = store.createLocation(name: "Concurrent Dishes")
        let dinnerTime = Date(timeIntervalSince1970: 1_720_000_000)
        let georgeVisit = store.logVisit(
            at: location, reaction: .liked, personID: george.id,
            date: dinnerTime, companionIDs: [michelle.id]
        )
        _ = store.addDish(
            name: "Spicy Ramen", role: .entree, reaction: .loved,
            wouldOrderAgain: true, to: georgeVisit, personID: george.id
        )
        let michelleVisit = store.logVisit(
            at: location, reaction: .loved, personID: michelle.id,
            date: dinnerTime.addingTimeInterval(5 * 60), companionIDs: [george.id]
        )
        let duplicateDish = DishEntity(context: store.context)
        duplicateDish.id = UUID()
        duplicateDish.name = " spicy ramen "
        duplicateDish.role = .entree
        duplicateDish.createdAt = .now
        duplicateDish.location = location
        let michelleEntry = DishEntryEntity(context: store.context)
        michelleEntry.id = UUID()
        michelleEntry.personID = michelle.id
        michelleEntry.reaction = .fine
        michelleEntry.wouldOrderAgain = false
        michelleEntry.createdAt = .now
        michelleEntry.dish = duplicateDish
        michelleEntry.visit = michelleVisit
        try persistence.save()

        store.reload()

        let outing = try XCTUnwrap(store.visits.first)
        XCTAssertEqual(store.visits.count, 1)
        XCTAssertEqual(location.dishArray.count, 1)
        XCTAssertEqual(outing.dishEntryArray.count, 2)
        XCTAssertEqual(Set(outing.dishEntryArray.compactMap { $0.dish?.id }).count, 1)
        XCTAssertEqual(Set(outing.dishEntryArray.map(\.personID)), Set([george.id, michelle.id]))
    }

    func testLoggingFindsAnExistingNearbyOutingThatAlreadyTaggedTheDiner() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let location = store.createLocation(name: "Already Shared")
        let dinnerTime = Date(timeIntervalSince1970: 1_720_000_000)
        let existing = store.logVisit(
            at: location, reaction: .loved, personID: george.id,
            date: dinnerTime, companionIDs: [michelle.id]
        )

        let match = store.existingOuting(
            at: location,
            near: dinnerTime.addingTimeInterval(4 * 60 * 60),
            for: michelle.id
        )

        XCTAssertEqual(match?.id, existing.id)
        XCTAssertNil(store.existingOuting(
            at: location,
            near: dinnerTime.addingTimeInterval(9 * 60 * 60),
            for: michelle.id
        ))
    }

    func testSharedOutingKeepsEachParticipantsMemoryIndependent() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let visit = store.logVisit(
            at: store.createLocation(name: "Two Memories"),
            reaction: .loved,
            personID: george.id,
            companionIDs: [michelle.id]
        )

        store.updateMemory("George remembered the patio.", for: visit, personID: george.id)
        store.updateMemory("Michelle remembered her pasta.", for: visit, personID: michelle.id)

        XCTAssertEqual(store.memory(for: visit, personID: george.id), "George remembered the patio.")
        XCTAssertEqual(store.memory(for: visit, personID: michelle.id), "Michelle remembered her pasta.")
    }

    func testAddingTheSameDishForOneDinerUpdatesTheirDishEntry() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let visit = store.logVisit(
            at: store.createLocation(name: "One Dish Entry"),
            reaction: .liked,
            personID: george.id
        )

        let first = try XCTUnwrap(store.addDish(
            name: "Pasta", role: .entree, reaction: .fine,
            wouldOrderAgain: false, to: visit, personID: george.id
        ))
        let updated = try XCTUnwrap(store.addDish(
            name: "pasta", role: .entree, reaction: .loved,
            wouldOrderAgain: true, to: visit, personID: george.id
        ))

        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(visit.dishEntryArray.filter { $0.personID == george.id }.count, 1)
        XCTAssertEqual(updated.reaction, .loved)
        XCTAssertTrue(updated.wouldOrderAgain)
    }

    func testDishEvidenceAdjustsTheVisitOnceWithoutASecondLocationBoost() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let location = store.createLocation(name: "Single Dish Influence")
        let visit = store.logVisit(at: location, reaction: .liked, personID: george.id)
        _ = store.addDish(
            name: "Excellent Noodles", role: .entree, reaction: .loved,
            wouldOrderAgain: true, to: visit, personID: george.id
        )

        let rating = try XCTUnwrap(visit.rating(for: george.id))
        let visitValue = store.rankingEngine.visitValue(visit: visit, rating: rating)
        let expectedScore = ((60 * 0.08) + visitValue) / 1.08

        let score = try XCTUnwrap(store.score(for: location, personID: george.id))
        XCTAssertEqual(score.score, expectedScore, accuracy: 0.000_001)
    }

    func testAnotherDinersDishNeverChangesMyVisitEvidence() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let visit = store.logVisit(
            at: store.createLocation(name: "Separate Plates"),
            reaction: .liked,
            personID: george.id,
            companionIDs: [michelle.id]
        )
        let georgeRating = try XCTUnwrap(visit.rating(for: george.id))
        let before = store.rankingEngine.visitValue(visit: visit, rating: georgeRating)

        _ = store.addDish(
            name: "Michelle's Curry", role: .entree, reaction: .notForMe,
            wouldOrderAgain: false, to: visit, personID: michelle.id
        )

        XCTAssertEqual(
            store.rankingEngine.visitValue(visit: visit, rating: georgeRating),
            before,
            accuracy: 0.000_001
        )
    }

    func testOnlyThePhotoContributorCanRemoveTheirSharedOutingPhoto() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let visit = store.logVisit(
            at: store.createLocation(name: "Owned Photos"),
            reaction: .liked,
            personID: george.id,
            companionIDs: [michelle.id]
        )
        store.addPhoto(
            fullData: Data([0x01]), thumbnailData: nil,
            to: visit, personID: george.id
        )
        let photo = try XCTUnwrap(visit.photoArray.first)

        XCTAssertFalse(store.deletePhoto(photo, personID: michelle.id))
        XCTAssertEqual(visit.photoArray.count, 1)
        XCTAssertTrue(store.deletePhoto(photo, personID: george.id))
        XCTAssertTrue(visit.photoArray.isEmpty)
    }

    func testSharedParticipantCanOnlyEditTheirOwnDinerEntry() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let originalLocation = store.createLocation(name: "Owned Outing")
        let otherLocation = store.createLocation(name: "Wrong Restaurant")
        let visit = store.logVisit(
            at: originalLocation,
            reaction: .liked,
            personID: george.id,
            companionIDs: [michelle.id]
        )
        let georgeDish = try XCTUnwrap(store.addDish(
            name: "George's Pasta", role: .entree, reaction: .liked,
            wouldOrderAgain: true, to: visit, personID: george.id
        ))
        let michelleDish = try XCTUnwrap(store.addDish(
            name: "Michelle's Soup", role: .entree, reaction: .loved,
            wouldOrderAgain: true, to: visit, personID: michelle.id
        ))

        XCTAssertFalse(store.changeLocation(of: visit, to: otherLocation, editorID: michelle.id))
        XCTAssertFalse(store.updateVisit(
            visit, type: .coffee, priceBand: 4, occasion: .dateNight,
            memory: "Not George's memory", companions: [], editorID: michelle.id
        ))
        XCTAssertFalse(store.deleteDishEntry(georgeDish, personID: michelle.id))
        XCTAssertFalse(store.deleteVisit(visit, personID: michelle.id))

        XCTAssertEqual(visit.location?.id, originalLocation.id)
        XCTAssertNil(visit.visitType)
        XCTAssertEqual(visit.priceBand, 0)
        XCTAssertTrue(store.visits.contains { $0.id == visit.id })
        XCTAssertTrue(visit.dishEntryArray.contains { $0.id == georgeDish.id })
        XCTAssertTrue(store.deleteDishEntry(michelleDish, personID: michelle.id))
    }

    func testCircleMemberWhoWasNotPartOfOutingCannotCreateDinerEntryOrChangeOutingDate() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let location = store.createLocation(name: "Private Table")
        let outingDate = Date(timeIntervalSince1970: 1_700_000_000)
        let photoDate = outingDate.addingTimeInterval(-86_400)
        let ratingVisit = store.logVisit(at: location, reaction: .liked, personID: george.id)
        let memoryVisit = store.logVisit(at: location, reaction: .liked, personID: george.id)
        let dishVisit = store.logVisit(at: location, reaction: .liked, personID: george.id)
        let photoVisit = store.logVisit(
            at: location,
            reaction: .liked,
            personID: george.id,
            date: outingDate
        )
        let declinedVisit = store.logVisit(at: location, reaction: .liked, personID: george.id)
        let notThereVisit = store.logVisit(at: location, reaction: .liked, personID: george.id)
        let invitedVisit = store.logVisit(
            at: location,
            reaction: .liked,
            personID: george.id,
            companionIDs: [michelle.id]
        )

        store.selectCurrentPerson(michelle.id)

        XCTAssertFalse(store.canEditDinerEntry(ratingVisit))
        XCTAssertTrue(store.canEditDinerEntry(invitedVisit))
        store.declineRating(for: invitedVisit)
        XCTAssertTrue(store.canEditDinerEntry(invitedVisit), "A participant who skipped a reaction was still there")
        store.markNotPresent(for: invitedVisit)
        XCTAssertFalse(store.canEditDinerEntry(invitedVisit))

        _ = store.addRating(to: ratingVisit, personID: michelle.id, reaction: .loved)
        store.updateMemory("I was not there.", for: memoryVisit, personID: michelle.id)
        let dish = store.addDish(
            name: "Someone else's dinner",
            role: .entree,
            reaction: .loved,
            wouldOrderAgain: true,
            to: dishVisit,
            personID: michelle.id
        )
        store.addPhoto(
            fullData: Data([0x01]),
            thumbnailData: nil,
            to: photoVisit,
            personID: michelle.id
        )
        store.updateVisitDateFromPhotoMetadata(
            photoVisit,
            photos: [BackfillPhoto(
                id: UUID(),
                fullData: Data([0x01]),
                thumbnailData: Data([0x01]),
                date: photoDate,
                coordinate: nil,
                captureDate: photoDate
            )]
        )
        store.declineRating(for: declinedVisit, personID: michelle.id)
        store.markNotPresent(for: notThereVisit, personID: michelle.id)

        XCTAssertNil(ratingVisit.rating(for: michelle.id))
        XCTAssertNil(ratingVisit.participant(for: michelle.id))
        XCTAssertNil(memoryVisit.participant(for: michelle.id))
        XCTAssertNil(dish)
        XCTAssertNil(dishVisit.participant(for: michelle.id))
        XCTAssertTrue(photoVisit.photoArray.isEmpty)
        XCTAssertNil(photoVisit.participant(for: michelle.id))
        XCTAssertEqual(photoVisit.date, outingDate)
        XCTAssertNil(declinedVisit.participant(for: michelle.id))
        XCTAssertNil(notThereVisit.participant(for: michelle.id))
    }

    func testOutingCreatorCannotOverrideAnotherMembersAttendanceResponseOrEntry() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let location = store.createLocation(name: "Authoritative Attendance")
        let contributed = store.logVisit(
            at: location, reaction: .liked, personID: george.id, companionIDs: [michelle.id]
        )
        _ = store.addRating(to: contributed, personID: michelle.id, reaction: .loved)

        XCTAssertTrue(store.updateVisit(
            contributed, type: nil, priceBand: 0, occasion: nil,
            memory: nil, companions: [], editorID: george.id
        ))
        XCTAssertEqual(contributed.participant(for: michelle.id)?.status, .attended)
        XCTAssertNotNil(contributed.rating(for: michelle.id))
        XCTAssertTrue(store.attendees(for: contributed).contains { $0.id == michelle.id })

        let rejected = store.logVisit(
            at: location, reaction: .fine, personID: george.id, companionIDs: [michelle.id]
        )
        store.markNotPresent(for: rejected, personID: michelle.id)
        XCTAssertTrue(store.updateVisit(
            rejected, type: nil, priceBand: 0, occasion: nil,
            memory: nil, companions: [michelle.id], editorID: george.id
        ))
        XCTAssertEqual(rejected.participant(for: michelle.id)?.status, .notThere)
        XCTAssertFalse(store.attendees(for: rejected).contains { $0.id == michelle.id })
        XCTAssertTrue(store.pendingVisits(for: michelle.id).isEmpty)
    }

    func testPersonalMemoryOrPhotoConfirmsAttendanceWithoutRequiringOverallRating() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let location = store.createLocation(name: "Nonrating Contributions")
        let memoryVisit = store.logVisit(
            at: location, reaction: .liked, personID: george.id, companionIDs: [michelle.id]
        )

        store.updateMemory("Michelle remembered the patio.", for: memoryVisit, personID: michelle.id)

        XCTAssertEqual(memoryVisit.participant(for: michelle.id)?.status, .attended)
        XCTAssertFalse(store.pendingVisits(for: michelle.id).contains { $0.id == memoryVisit.id })

        let photoVisit = store.logVisit(
            at: location, reaction: .fine, personID: george.id, companionIDs: [michelle.id]
        )
        store.addPhoto(
            fullData: Data([0x01]), thumbnailData: nil,
            to: photoVisit, personID: michelle.id
        )

        XCTAssertEqual(photoVisit.participant(for: michelle.id)?.status, .attended)
        XCTAssertFalse(store.pendingVisits(for: michelle.id).contains { $0.id == photoVisit.id })
    }

    func testCircleRankingIsIndependentOfWhichMemberUsesTheDevice() throws {
        let george = try XCTUnwrap(store.currentPerson)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let sam = try XCTUnwrap(store.addCircleMember(name: "Sam"))
        let location = store.createLocation(name: "Consensus Cafe", category: .coffeeTea)
        let visit = store.logVisit(
            at: location,
            reaction: .loved,
            companionIDs: [michelle.id, sam.id]
        )
        _ = store.addRating(to: visit, personID: michelle.id, reaction: .liked)
        _ = store.addRating(to: visit, personID: sam.id, reaction: .fine)

        let before = try XCTUnwrap(store.circleRanked().first)
        store.selectCurrentPerson(michelle.id)
        let after = try XCTUnwrap(store.circleRanked().first)

        XCTAssertEqual(before.id, location.id)
        XCTAssertEqual(before.memberScores.map(\.personID), after.memberScores.map(\.personID))
        XCTAssertEqual(before.score, after.score, accuracy: 0.000_001)
        XCTAssertEqual(Set(before.memberScores.map(\.personID)), Set([george.id, michelle.id, sam.id]))
    }

    /// Joining somebody's circle has to bring this iPhone's dining history with
    /// it. A member who joins and then imports a restaurant list expects the
    /// rest of the circle to see it, and the previous behaviour — a second,
    /// private circle nobody else could read — is what made shared logs look
    /// broken.
    func testJoiningACircleCarriesThisDevicesLogIntoIt() throws {
        let joinedCircleID = UUID()
        let location = store.createLocation(name: "Carried Cafe", category: .coffeeTea)
        let visit = store.logVisit(at: location, reaction: .loved)
        let originalCircleID = try XCTUnwrap(store.activeCircleID)

        let personID = try XCTUnwrap(store.adoptCircle(id: joinedCircleID, name: "Kelsey's Table"))

        XCTAssertNotEqual(joinedCircleID, originalCircleID)
        XCTAssertEqual(store.activeCircleID, joinedCircleID)
        XCTAssertEqual(store.circles.count, 1)
        XCTAssertEqual(store.activeCircle?.name, "Kelsey's Table")
        XCTAssertEqual(store.currentPerson?.id, personID)
        XCTAssertEqual(store.locations.map(\.id), [location.id])
        XCTAssertEqual(store.visits.map(\.id), [visit.id])
        XCTAssertEqual(store.locations.first?.circle?.id, joinedCircleID)
        XCTAssertEqual(store.visits.first?.circle?.id, joinedCircleID)
    }

    /// The circle can arrive from a sync pull before the join finishes. Both
    /// copies then have to become one log rather than two.
    func testJoiningACircleThatAlreadyDownloadedMergesTheTwoLogs() throws {
        let originalPersonID = try XCTUnwrap(store.currentPerson?.id)
        let mine = store.createLocation(name: "My Place", category: .fullService)
        let downloaded = try makeCircle(name: "Kelsey's Table", people: ["Kelsey"])

        _ = try XCTUnwrap(store.adoptCircle(id: downloaded.circle.id))

        XCTAssertEqual(store.circles.count, 1)
        XCTAssertEqual(store.activeCircleID, downloaded.circle.id)
        XCTAssertTrue(store.locations.contains { $0.id == mine.id })
        XCTAssertEqual(store.locations.first { $0.id == mine.id }?.circle?.id, downloaded.circle.id)
        XCTAssertTrue(store.circleMembers.contains { $0.name == "Kelsey" })
        XCTAssertTrue(store.circleMembers.contains { $0.name == "George" })
        XCTAssertEqual(store.currentPerson?.id, originalPersonID)
        XCTAssertEqual(store.currentPerson?.name, "George")
    }

    /// Leaving must never delete the dining log. Deleting a circle graph while
    /// the interface still held its rows is what crashed the app.
    func testLeavingKeepsEveryRecordUnderAFreshIdentity() throws {
        let georgeID = try XCTUnwrap(store.currentPerson?.id)
        let michelleID = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" }?.id)
        let location = store.createLocation(name: "Kept Kitchen", category: .fullService)
        let visit = store.logVisit(at: location, reaction: .liked, companionIDs: [michelleID])
        let sharedCircleID = try XCTUnwrap(store.activeCircleID)

        let newID = try XCTUnwrap(store.startFreshCircleIdentity())

        XCTAssertNotEqual(newID, sharedCircleID)
        XCTAssertEqual(store.circles.count, 1)
        XCTAssertEqual(store.activeCircleID, newID)
        XCTAssertEqual(store.locations.map(\.id), [location.id])
        XCTAssertEqual(store.visits.map(\.id), [visit.id])
        XCTAssertEqual(store.currentPerson?.id, georgeID)
        XCTAssertEqual(store.currentPerson?.name, "George")
        XCTAssertEqual(store.circleMembers.map(\.id), [georgeID])
        XCTAssertTrue(store.namedCompanions.contains { $0.id == michelleID })
        XCTAssertTrue(store.attendees(for: visit).contains { $0.id == michelleID })
    }

    func testLeavingDemotesAnArchivedFormerMemberToo() throws {
        let georgeID = try XCTUnwrap(store.currentPerson?.id)
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        michelle.isArchived = true
        try persistence.save()

        _ = try XCTUnwrap(store.startFreshCircleIdentity())

        XCTAssertEqual(store.currentPerson?.id, georgeID)
        XCTAssertFalse(michelle.isCircleMember)
        XCTAssertTrue(michelle.isArchived)
    }

    func testSameNamedMembersNeverMergeOrMoveThisPhonesIdentity() throws {
        let georgeID = try XCTUnwrap(store.currentPerson?.id)
        let secondGeorge = PersonEntity(context: store.context)
        secondGeorge.id = UUID()
        secondGeorge.name = "George"
        secondGeorge.isMe = false
        secondGeorge.isCircleMember = true
        secondGeorge.colorHex = "2F5964"
        secondGeorge.createdAt = .now.addingTimeInterval(1)
        secondGeorge.circle = try XCTUnwrap(store.activeCircle)
        try persistence.save()

        store.reload()

        XCTAssertEqual(store.circleMembers.filter { $0.name == "George" }.count, 2)
        XCTAssertEqual(store.currentPerson?.id, georgeID)
    }

    func testServerPreferenceCannotReplaceAnExistingDeviceIdentity() throws {
        let georgeID = try XCTUnwrap(store.currentPerson?.id)
        let michelleID = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" }?.id)

        XCTAssertEqual(store.adoptDeviceIdentity(preferring: michelleID), georgeID)
        XCTAssertEqual(store.currentPerson?.id, georgeID)
    }

    func testLoggingIdentityRecoveryNeverGuessesBetweenCircleMembers() throws {
        let circleID = try XCTUnwrap(store.activeCircle?.id)
        store.completeBackupRestore(activeCircleID: circleID, selections: [:])

        XCTAssertNil(store.currentPerson)
        XCTAssertNil(store.resolveLoggingPersonID())
        XCTAssertNil(store.currentPerson)
    }

    func testOrphanedHistoricalProfileCanBeMergedIntoConnectedMemberWithoutLosingRankings() throws {
        let georgeID = try XCTUnwrap(store.currentPerson?.id)
        let kelseyG = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        XCTAssertTrue(store.renamePerson(kelseyG, to: "Kelsey G"))
        let importedKelsey = try XCTUnwrap(store.addNamedCompanion(name: "Kelsey"))
        let importedKelseyID = importedKelsey.id
        let kelseyGID = kelseyG.id
        // Older backups can retain stale member/archive flags even though no
        // current server membership points at this historical profile.
        importedKelsey.isCircleMember = true
        importedKelsey.isArchived = true
        let first = store.createLocation(name: "Kelsey's Favorite", category: .fullService)
        let second = store.createLocation(name: "Kelsey's Runner Up", category: .fullService)
        let visit = store.logVisit(
            at: first,
            reaction: .liked,
            personID: georgeID,
            companionIDs: [importedKelseyID]
        )
        _ = store.addRating(to: visit, personID: importedKelseyID, reaction: .loved)
        store.updateMemory("Kelsey remembered this dinner.", for: visit, personID: importedKelseyID)
        let dish = try XCTUnwrap(store.addDish(
            name: "Kelsey's Pasta",
            role: .entree,
            reaction: .loved,
            wouldOrderAgain: true,
            to: visit,
            personID: importedKelseyID
        ))
        store.addPhoto(
            fullData: Data([0x01, 0x02]),
            thumbnailData: Data([0x03]),
            to: visit,
            personID: importedKelseyID
        )
        store.recordComparison(
            a: first,
            b: second,
            outcome: .a,
            personID: importedKelseyID
        )
        store.toggleWant(second, by: importedKelseyID)

        let connectedMemberIDs: Set<UUID> = [georgeID, kelseyGID]
        XCTAssertFalse(store.mergeHistoricalProfile(
            georgeID,
            into: kelseyGID,
            connectedMemberIDs: connectedMemberIDs
        ))
        XCTAssertFalse(store.mergeHistoricalProfile(
            importedKelseyID,
            into: kelseyGID,
            connectedMemberIDs: connectedMemberIDs.union([importedKelseyID])
        ))
        XCTAssertTrue(store.mergeHistoricalProfile(
            importedKelseyID,
            into: kelseyGID,
            connectedMemberIDs: connectedMemberIDs
        ))

        let restoredVisit = try XCTUnwrap(store.visits.first { $0.id == visit.id })
        XCTAssertNil(store.person(id: importedKelseyID))
        XCTAssertNotNil(store.person(id: kelseyGID))
        XCTAssertTrue(restoredVisit.companionIDs.contains(kelseyGID))
        XCTAssertNil(restoredVisit.rating(for: importedKelseyID))
        XCTAssertEqual(restoredVisit.rating(for: kelseyGID)?.reaction, .loved)
        XCTAssertEqual(store.memory(for: restoredVisit, personID: kelseyGID), "Kelsey remembered this dinner.")
        XCTAssertEqual(dish.personID, kelseyGID)
        XCTAssertEqual(restoredVisit.photoArray.first?.personID, kelseyGID)
        XCTAssertTrue(store.comparisons.allSatisfy { $0.personID != importedKelseyID })
        XCTAssertTrue(store.comparisons.contains { $0.personID == kelseyGID })
        XCTAssertTrue(store.wantEntries.allSatisfy { $0.addedByID != importedKelseyID })
        XCTAssertTrue(store.wantEntries.contains { $0.addedByID == kelseyGID })
        XCTAssertFalse(store.ranked(for: kelseyGID).isEmpty)
        XCTAssertEqual(store.currentPerson?.id, georgeID)
    }

    func testExtraCirclesFromOlderBuildsAreFoldedIntoOneLog() throws {
        let mine = store.createLocation(name: "Mine", category: .fullService)
        let stranded = try makeCircle(name: "Stranded", people: ["Ghost"])
        let strandedLocation = RestaurantLocation(context: store.context)
        strandedLocation.id = UUID()
        strandedLocation.name = "Stranded Diner"
        strandedLocation.categoryRaw = DiningCategory.fullService.rawValue
        strandedLocation.createdAt = .now
        strandedLocation.updatedAt = .now
        strandedLocation.circle = stranded.circle
        try persistence.save()
        store.reload()
        XCTAssertEqual(store.circles.count, 2)

        XCTAssertTrue(store.consolidateCircles())

        XCTAssertEqual(store.circles.count, 1)
        XCTAssertEqual(Set(store.locations.map(\.name)), ["Mine", "Stranded Diner"])
        XCTAssertTrue(store.locations.allSatisfy { $0.circle?.id == store.activeCircleID })
        XCTAssertTrue(store.circleMembers.contains { $0.name == "Ghost" })
        XCTAssertEqual(store.currentPerson?.name, "George")
        XCTAssertNotNil(store.locations.first { $0.id == mine.id })
    }

    func testPersistenceFailuresBecomeUserVisible() async {
        NotificationCenter.default.post(
            name: .persistenceDidFail,
            object: persistence,
            userInfo: [PersistenceNotificationKey.message: "The test save failed."]
        )
        await Task.yield()

        XCTAssertEqual(store.lastError, "The test save failed.")
        store.clearLastError()
        XCTAssertNil(store.lastError)
    }

    func testBatchKeepsCachesCurrentWithoutFullReloads() throws {
        let personID = try XCTUnwrap(store.currentPerson?.id)
        let reloadsBefore = store.diagnosticReloadCount

        store.performBatch {
            for index in 0..<50 {
                let location = store.createLocation(name: "Batch Place \(index)", category: .fullService)
                let visit = store.logVisit(at: location, reaction: .loved)
                store.updateVisit(visit, type: .meal, priceBand: 2, occasion: nil, memory: "Batch note", companions: [])
                _ = store.addDish(name: "Batch dish", role: .entree, reaction: .loved, wouldOrderAgain: true, to: visit, personID: personID)
            }
            let first = store.createLocation(name: "Repeated Place", category: .fullService)
            let second = store.createLocation(name: "repeated place", category: .fullService)
            XCTAssertEqual(first.id, second.id, "In-memory batch caches must preserve location deduplication")
        }

        XCTAssertEqual(store.diagnosticReloadCount, reloadsBefore, "Local batches should publish without refetching the store")
        XCTAssertEqual(store.locations.count, 51)
        XCTAssertEqual(store.visits.count, 50)
    }

    func testNameOnlyCreationReusesUniqueAddressedRestaurant() {
        let mapped = store.createLocation(
            name: "Branch Bistro",
            address: "123 Main Street",
            coordinate: (40.75, -111.89)
        )

        let manual = store.createLocation(name: "branch bistro")

        XCTAssertEqual(manual.id, mapped.id)
        XCTAssertEqual(store.locations.count, 1)
    }

    func testNameOnlyCreationDoesNotMergeAmbiguousBranches() {
        let first = store.createLocation(
            name: "Branch Bistro",
            address: "123 Main Street",
            forceDistinct: true
        )
        let second = store.createLocation(
            name: "Branch Bistro",
            address: "456 State Street",
            forceDistinct: true
        )

        let manual = store.createLocation(name: "Branch Bistro")

        XCTAssertNotEqual(manual.id, first.id)
        XCTAssertNotEqual(manual.id, second.id)
        XCTAssertEqual(store.locations.count, 3)
    }

    func testRestaurantRoutePreservesRankingScope() {
        let locationID = UUID()
        let personID = UUID()

        XCTAssertNotEqual(
            AppRoute.location(locationID, rankingScope: .person(personID)),
            AppRoute.location(locationID, rankingScope: .circle)
        )
    }

    func testCircleJoinImpactCountsEverythingThatWillBecomeShared() throws {
        let first = store.createLocation(name: "Local Favorite")
        let second = store.createLocation(name: "Another Favorite")
        let outing = store.logVisit(at: first, reaction: .loved)
        store.addPhoto(fullData: Data([0x01]), thumbnailData: nil, to: outing)
        store.toggleWant(second)
        store.recordComparison(a: first, b: second, outcome: .a)

        let impact = store.circleJoinImpact

        XCTAssertEqual(impact.restaurants, 2)
        XCTAssertEqual(impact.outings, 1)
        XCTAssertEqual(impact.photos, 1)
        XCTAssertEqual(impact.wantToTryEntries, 1)
        XCTAssertEqual(impact.reactions, 1)
        XCTAssertEqual(impact.rankingAnswers, 1)
        XCTAssertTrue(impact.hasShareableData)
    }

    func testRemoteChangeBurstsAreCoalesced() async throws {
        let reloadsBefore = store.diagnosticReloadCount

        for _ in 0..<50 {
            NotificationCenter.default.post(
                name: .NSPersistentStoreRemoteChange,
                object: persistence.container.persistentStoreCoordinator
            )
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(store.diagnosticReloadCount - reloadsBefore, 1)
    }

    func testCircleArrivingFromSyncAnnouncesItselfAndBecomesActive() async throws {
        let emptyPersistence = PersistenceController(inMemory: true)
        let emptyStore = AppStore(persistence: emptyPersistence)
        XCTAssertTrue(emptyStore.circles.isEmpty)
        let restored = expectation(
            forNotification: .circleDidArriveFromSync,
            object: emptyStore
        )

        let circle = CircleEntity(context: emptyStore.context)
        circle.id = UUID()
        circle.name = "Restored Circle"
        circle.createdAt = .now
        try emptyPersistence.save()
        NotificationCenter.default.post(
            name: .NSPersistentStoreRemoteChange,
            object: emptyPersistence.container.persistentStoreCoordinator
        )

        await fulfillment(of: [restored], timeout: 1)
        XCTAssertEqual(emptyStore.activeCircle?.name, "Restored Circle")
    }

    func testCircleArrivingFromSyncBecomesActiveEvenWhenALocalCircleExists() async throws {
        let localCircleID = try XCTUnwrap(store.activeCircleID)
        let restored = expectation(
            forNotification: .circleDidArriveFromSync,
            object: store
        )

        let circle = CircleEntity(context: store.context)
        circle.id = UUID()
        circle.name = "Joined Circle"
        circle.createdAt = .now
        try persistence.save()
        NotificationCenter.default.post(
            name: .NSPersistentStoreRemoteChange,
            object: persistence.container.persistentStoreCoordinator
        )

        await fulfillment(of: [restored], timeout: 1)
        XCTAssertNotEqual(store.activeCircleID, localCircleID)
        XCTAssertEqual(store.activeCircle?.name, "Joined Circle")
    }

    func testEraseAllDataRemovesEveryEntityAndDeviceIdentity() throws {
        let circleID = try XCTUnwrap(store.activeCircleID)
        let location = store.createLocation(name: "Reset Test", category: .fullService)
        let visit = store.logVisit(at: location, reaction: .loved)
        store.addPhoto(fullData: Data([0x01]), thumbnailData: Data([0x02]), to: visit)
        store.toggleWant(location)
        store.recordAnchor(for: location, value: 85)
        _ = store.addNamedCompanion(name: "Guest")
        var scheduledCircleIDs: [UUID] = []
        store.didCommit = { scheduledCircleIDs.append($0) }

        XCTAssertTrue(store.eraseAllData())
        XCTAssertEqual(scheduledCircleIDs, [circleID])
        XCTAssertNil(store.activeCircle)
        XCTAssertNil(store.currentPerson)
        XCTAssertNil(UserDefaults.standard.string(forKey: "activeCircleID"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "devicePersonID"))
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: "devicePersonIDsByCircle"))

        for entity in persistence.container.managedObjectModel.entities {
            guard let entityName = entity.name else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            XCTAssertEqual(try store.context.count(for: request), 0, "Expected \(entityName) to be empty after reset")
        }
    }

    func testRankingHistoryReplaysEvidenceAtRecordedTimesIncludingSameDayChanges() throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let first = store.createLocation(name: "History First", category: .fullService)
        let second = store.createLocation(name: "History Second", category: .fullService)
        let firstVisit = store.logVisit(at: first, reaction: .loved, date: baseDate.addingTimeInterval(-86_400))
        let secondVisit = store.logVisit(at: second, reaction: .liked, date: baseDate.addingTimeInterval(-86_400))

        try XCTUnwrap(firstVisit.ratingArray.first).createdAt = baseDate.addingTimeInterval(60)
        try XCTUnwrap(secondVisit.ratingArray.first).createdAt = baseDate.addingTimeInterval(120)
        let comparisonID = try XCTUnwrap(store.recordComparison(a: first, b: second, outcome: .a))
        try XCTUnwrap(store.comparisons.first { $0.id == comparisonID }).date = baseDate.addingTimeInterval(180)

        let endDate = baseDate.addingTimeInterval(240)
        let snapshots = RankingHistoryBuilder().personSnapshots(
            locations: store.locations,
            comparisons: store.comparisons,
            personID: try XCTUnwrap(store.currentPerson?.id),
            through: endDate
        )

        XCTAssertEqual(snapshots.map(\.date), [
            baseDate.addingTimeInterval(60),
            baseDate.addingTimeInterval(120),
            baseDate.addingTimeInterval(180),
            endDate
        ])
        XCTAssertEqual(snapshots[0].scores.map(\.locationName), ["History First"])
        XCTAssertEqual(Set(snapshots[1].scores.map(\.locationName)), ["History First", "History Second"])
        XCTAssertEqual(snapshots[2].scores.count, 2)
    }

    func testRankingHistoryDoesNotShowEvidenceBeforeItWasRecorded() throws {
        let baseDate = Date(timeIntervalSince1970: 1_710_000_000)
        let location = store.createLocation(name: "Future Evidence", category: .bakeries)
        let visit = store.logVisit(at: location, reaction: .loved, date: baseDate.addingTimeInterval(-86_400))
        try XCTUnwrap(visit.ratingArray.first).createdAt = baseDate.addingTimeInterval(3_600)

        let beforeRating = RankingHistoryBuilder().personSnapshots(
            locations: store.locations,
            comparisons: store.comparisons,
            personID: try XCTUnwrap(store.currentPerson?.id),
            through: baseDate.addingTimeInterval(1_800)
        )
        let afterRating = RankingHistoryBuilder().personSnapshots(
            locations: store.locations,
            comparisons: store.comparisons,
            personID: try XCTUnwrap(store.currentPerson?.id),
            through: baseDate.addingTimeInterval(7_200)
        )

        XCTAssertTrue(beforeRating.isEmpty)
        XCTAssertFalse(afterRating.isEmpty)
        XCTAssertEqual(afterRating.first?.scores.first?.locationName, "Future Evidence")
    }

    private func makeCircle(name: String, people: [String]) throws -> (circle: CircleEntity, people: [PersonEntity]) {
        let circle = CircleEntity(context: store.context)
        circle.id = UUID()
        circle.name = name
        circle.createdAt = .now
        let members = people.map { name in
            let person = PersonEntity(context: store.context)
            person.id = UUID()
            person.name = name
            person.isMe = false
            person.isCircleMember = true
            person.colorHex = "6F1D2B"
            person.createdAt = .now
            person.circle = circle
            return person
        }
        try persistence.save()
        store.reload()
        return (circle, members)
    }
}
