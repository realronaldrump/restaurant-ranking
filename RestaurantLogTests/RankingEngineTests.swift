import CoreLocation
import CoreData
import CloudKit
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
        persistence = PersistenceController(inMemory: true, cloudEnabled: false)
        store = AppStore(persistence: persistence)
        store.bootstrap(myName: "George")
        XCTAssertNotNil(store.addCircleMember(name: "Michelle"))
    }

    func testManagedObjectModelMeetsCloudKitAttributeRequirements() {
        let model = ManagedObjectModel.make()
        let invalidAttributes = model.entities.flatMap { entity in
            entity.attributesByName.values.compactMap { attribute -> String? in
                guard !attribute.isOptional, attribute.defaultValue == nil else { return nil }
                return "\(entity.name ?? "Unknown").\(attribute.name)"
            }
        }

        XCTAssertEqual(invalidAttributes, [], "CloudKit requires every non-optional attribute to have a default value")
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

        let sanitizedSource = try XCTUnwrap(CGImageSourceCreateWithData(photo.fullData as CFData, nil))
        let sanitizedProperties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(sanitizedSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertNil(sanitizedProperties[kCGImagePropertyGPSDictionary])
        let sanitizedExif = sanitizedProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(sanitizedExif?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(sanitizedExif?[kCGImagePropertyExifOffsetTimeOriginal])
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

    func testRenamingAPersonUpdatesEveryLinkedVisitName() throws {
        let michelle = try XCTUnwrap(store.circleMembers.first { $0.name == "Michelle" })
        let visit = store.logVisit(at: store.createLocation(name: "Rename Table"), reaction: .liked, companionIDs: [michelle.id])

        XCTAssertTrue(store.renamePerson(michelle, to: "Mickey"))

        XCTAssertEqual(store.taggedPeople(for: visit).map(\.name), ["Mickey"])
        XCTAssertEqual(store.attendees(for: visit).map(\.name), ["George", "Mickey"])
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

    func testReloadConvergesConcurrentSameNameMembersOnOneCanonicalIdentity() throws {
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
        visit.companionIDs = [concurrentMichelle.id]
        _ = store.addRating(to: visit, personID: michelle.id, reaction: .fine)
        _ = store.addRating(to: visit, personID: concurrentMichelle.id, reaction: .liked)
        _ = store.addDish(
            name: "Shared Soup", role: .appetizer, reaction: .fine,
            wouldOrderAgain: false, to: visit, personID: michelle.id
        )
        _ = store.addDish(
            name: "Shared Soup", role: .appetizer, reaction: .loved,
            wouldOrderAgain: true, to: visit, personID: concurrentMichelle.id
        )
        try persistence.save()

        store.reload()

        let restoredVisit = try XCTUnwrap(store.visits.first { $0.id == visit.id })
        XCTAssertEqual(store.circleMembers.filter {
            $0.name.trimmingCharacters(in: .whitespaces).localizedCaseInsensitiveCompare("Michelle") == .orderedSame
        }.map(\.id), [michelle.id])
        XCTAssertEqual(restoredVisit.companionIDs, [michelle.id])
        XCTAssertEqual(restoredVisit.ratingArray.count, 2, "George and the canonical Michelle should each retain one rating")
        XCTAssertEqual(restoredVisit.rating(for: michelle.id)?.reaction, .liked, "The newest duplicate rating should win")
        XCTAssertEqual(restoredVisit.dishEntryArray.filter { $0.personID == michelle.id }.count, 1)
        XCTAssertEqual(restoredVisit.dishEntryArray.first { $0.personID == michelle.id }?.reaction, .loved)
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
        let firstVisit = store.logVisit(at: first, reaction: .loved, personID: me.id)
        let secondVisit = store.logVisit(at: second, reaction: .liked, personID: me.id)
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
        XCTAssertTrue(location.visitArray.isEmpty)
        XCTAssertTrue(location.dishArray.isEmpty)
        XCTAssertFalse(store.ranked().contains { $0.id == locationID })
        for entityName in ["VisitEntity", "RatingEntity", "DishEntity", "DishEntryEntity", "PhotoEntity"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            XCTAssertEqual(try store.context.count(for: request), 0, "Expected \(entityName) to be removed with the visit")
        }
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

    func testUnboundCircleRequiresExplicitDeviceIdentity() throws {
        let second = try makeCircle(name: "Shared Circle", people: ["Owner", "Invited Guest"])

        store.activateCircle(second.circle.id)

        XCTAssertNil(store.currentPerson, "A newly accepted shared circle must not silently act as its owner")
    }

    func testDeviceIdentityIsRememberedPerCircle() throws {
        let originalCircleID = try XCTUnwrap(store.activeCircle?.id)
        let second = try makeCircle(name: "Shared Circle", people: ["Owner", "Invited Guest"])
        let invitedGuest = try XCTUnwrap(second.people.first { $0.name == "Invited Guest" })

        store.activateCircle(second.circle.id)
        store.selectCurrentPerson(invitedGuest.id)
        store.activateCircle(originalCircleID)
        store.activateCircle(second.circle.id)

        XCTAssertEqual(store.currentPerson?.id, invitedGuest.id)
    }

    func testCloudSharingReusesAnExistingShare() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "ExistingShare", ownerName: CKCurrentUserDefaultName)
        let existingShare = CKShare(recordZoneID: zoneID)
        let existingPayload = SharePayload(share: existingShare, container: CKContainer.default())
        var createCallCount = 0
        let service = CloudSharingService(
            existingPayload: { _, _ in existingPayload },
            newPayload: { _, _ in
                createCallCount += 1
                return existingPayload
            }
        )

        let payload = try await service.payload(for: try XCTUnwrap(store.activeCircle), persistence: persistence)

        XCTAssertEqual(createCallCount, 0)
        XCTAssertEqual(payload.share.recordID, existingShare.recordID)
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

    func testEraseAllDataRemovesEveryEntityAndDeviceIdentity() throws {
        let location = store.createLocation(name: "Reset Test", category: .fullService)
        let visit = store.logVisit(at: location, reaction: .loved)
        store.addPhoto(fullData: Data([0x01]), thumbnailData: Data([0x02]), to: visit)
        store.toggleWant(location)
        store.recordAnchor(for: location, value: 85)
        _ = store.addNamedCompanion(name: "Guest")

        XCTAssertTrue(store.eraseAllData())
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
