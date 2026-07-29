import XCTest
@testable import RestaurantLog

@MainActor
final class BeliImporterTests: XCTestCase {
    override func setUp() async throws {
        for key in ["activeCircleID", "devicePersonID", "devicePersonIDsByCircle"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testParsesBeliTablesWithKnownAndUnknownVisitsPhotosAndDishes() throws {
        let rankings = """
        Rank,Restaurant Name,City,Category,Created Date,Visit Dates
        1,"Cafe, Central","Waco, TX",RES,2025-10-08 22:36:02.168456+00:00,"[datetime.date(2025, 10, 8), datetime.date(2025, 11, 2)]"
        2,Second Place,"Waco, TX",RES,2025-07-21 03:12:33.862605+00:00,[]
        """
        let photos = """
        Business Name,City,Description,Is Favorite Dish,Upload Date,Image URL
        "Cafe, Central","Waco, TX","The ""best"" bun",True,2025-10-08 22:36:03.127913+00:00,https://photos.example.com/a.jpg
        """
        let dishes = """
        Field Type,Business Name,City,Note Text,Created Date
        Favorite Dishes,"Cafe, Central","Waco, TX",Cardamom Bun,2025-10-08 22:36:04.000000+00:00
        """
        let details = """
        user_id,export_date
        test-user,2026-07-22T06:41:11.014603+00:00
        """

        let archive = try BeliImporter.parse(files: [
            "rankings.csv": Data(rankings.utf8), "photos.csv": Data(photos.utf8),
            "notes_dishes.csv": Data(dishes.utf8), "export_details.csv": Data(details.utf8)
        ])

        XCTAssertEqual(archive.rankings.count, 2)
        XCTAssertEqual(archive.rankings[0].restaurantName, "Cafe, Central")
        XCTAssertEqual(archive.knownVisitCount, 2)
        XCTAssertEqual(archive.unknownVisitCount, 1)
        XCTAssertEqual(archive.photos.first?.caption, "The \"best\" bun")
        XCTAssertEqual(archive.photos.first?.isFavoriteDish, true)
        XCTAssertEqual(archive.dishNotes.first?.name, "Cardamom Bun")
        XCTAssertFalse(archive.namespace.contains("test-user"))
    }

    func testRejectsMissingRequiredRankingColumn() {
        let rankings = "Rank,Restaurant Name,City,Created Date\n1,Place,City,2025-01-01 00:00:00+00:00\n"
        XCTAssertThrowsError(try BeliImporter.parse(files: ["rankings.csv": Data(rankings.utf8)])) { error in
            XCTAssertEqual(error as? BeliImporter.ImportError, .missingColumn(file: "rankings.csv", column: "Visit Dates"))
        }
    }

    func testRejectsMalformedVisitDatesInsteadOfSilentlyMakingThemUnknown() {
        let rankings = "Rank,Restaurant Name,City,Created Date,Visit Dates\n1,Place,City,2025-01-01 00:00:00+00:00,not-a-date-list\n"
        XCTAssertThrowsError(try BeliImporter.parse(files: ["rankings.csv": Data(rankings.utf8)])) { error in
            XCTAssertEqual(
                error as? BeliImporter.ImportError,
                .invalidRow(file: "rankings.csv", row: 2, detail: "Visit Dates is not recognized.")
            )
        }
    }

    func testImportIsIdempotentAndKeepsUnknownDateOuting() throws {
        let persistence = PersistenceController(inMemory: true)
        let store = AppStore(persistence: persistence)
        store.bootstrap(myName: "Davis")
        let created = Date(timeIntervalSince1970: 1_750_000_000)
        let row = BeliRankingRow(
            id: "restaurant-key", rank: 1, restaurantName: "Unknown Date Cafe",
            city: "Waco, TX", createdAt: created, visitDates: []
        )
        let archive = BeliParsedArchive(
            namespace: "namespace", exportDate: created, rankings: [row], photos: [], dishNotes: []
        )
        let request = BeliImportRequest(
            archive: archive, resolutions: [row.id: .unresolved(markClosed: false)],
            photoRankingAssignments: [:], dishRankingAssignments: [:], downloadedPhotos: [:]
        )

        let first = store.importBeli(request)
        let second = store.importBeli(request)

        XCTAssertEqual(first.restaurantsCreated, 1)
        XCTAssertEqual(first.outingsCreated, 1)
        XCTAssertEqual(first.rankingsSeeded, 1)
        XCTAssertEqual(second.restaurantsCreated, 0)
        XCTAssertEqual(second.outingsCreated, 0)
        XCTAssertEqual(store.locations.count, 1)
        XCTAssertEqual(store.visits.count, 1)
        XCTAssertEqual(store.visits.first?.dateKnowledge, .unknown)
        XCTAssertEqual(store.ranked().first?.location.name, "Unknown Date Cafe")

        let session = try XCTUnwrap(store.beliImportSessions.first)
        let circleID = try XCTUnwrap(store.activeCircleID)
        var scheduledCircleIDs: [UUID] = []
        store.didCommit = { scheduledCircleIDs.append($0) }
        let deleted = try XCTUnwrap(store.deleteBeliImport(sessionID: session.id))
        XCTAssertEqual(scheduledCircleIDs, [circleID])
        XCTAssertEqual(deleted.restaurantsDeleted, 1)
        XCTAssertEqual(deleted.outingsDeleted, 1)
        XCTAssertEqual(deleted.rankingsDeleted, 1)
        XCTAssertTrue(store.locations.isEmpty)
        XCTAssertTrue(store.visits.isEmpty)
    }

    func testUnknownDateRatingUsesNeutralRecency() throws {
        let persistence = PersistenceController(inMemory: true)
        let store = AppStore(persistence: persistence)
        store.bootstrap(myName: "Davis")
        let location = store.createLocation(name: "Old but Unknown")
        let visit = store.logVisit(
            at: location, reaction: .loved,
            date: Date(timeIntervalSince1970: 100), dateKnowledge: .unknown
        )

        let score = try XCTUnwrap(store.score(for: location))
        XCTAssertEqual(visit.dateKnowledge, .unknown)
        XCTAssertGreaterThan(score.certainty, 0.9)
    }

    func testDeletingImportRemovesCreatedDataButPreservesMatchedExistingRecords() throws {
        let store = AppStore(persistence: PersistenceController(inMemory: true))
        store.bootstrap(myName: "Davis")
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let location = store.createLocation(name: "Existing Cafe", city: "Waco, TX")
        let existingVisit = store.logVisit(at: location, reaction: .liked, date: date)
        let ranking = BeliRankingRow(
            id: "existing-restaurant", rank: 1, restaurantName: "Existing Cafe",
            city: "Waco, TX", createdAt: date, visitDates: [date]
        )
        let photoRow = BeliPhotoRow(
            id: "photo-1", restaurantName: "Existing Cafe", city: "Waco, TX",
            caption: "A memorable plate", isFavoriteDish: false, uploadDate: date,
            imageURL: try XCTUnwrap(URL(string: "https://example.com/photo.jpg"))
        )
        let dishRow = BeliDishNoteRow(
            id: "dish-1", restaurantName: "Existing Cafe", city: "Waco, TX",
            name: "Cardamom Bun", createdAt: date
        )
        let archive = BeliParsedArchive(
            namespace: "namespace", exportDate: date,
            rankings: [ranking], photos: [photoRow], dishNotes: [dishRow]
        )
        let downloaded = BeliDownloadedPhoto(
            row: photoRow,
            photo: BackfillPhoto(
                id: UUID(), fullData: Data([1, 2, 3]), thumbnailData: Data([1]),
                date: date, coordinate: nil, captureDate: nil
            ),
            contentHash: "photo-content"
        )
        let request = BeliImportRequest(
            archive: archive, resolutions: [ranking.id: .existing(location.id)],
            photoRankingAssignments: [:], dishRankingAssignments: [:],
            downloadedPhotos: [photoRow.id: downloaded]
        )

        let imported = store.importBeli(request)
        let session = try XCTUnwrap(store.beliImportSessions.first)
        XCTAssertEqual(imported.outingsLinked, 1)
        XCTAssertEqual(existingVisit.photoArray.count, 1)
        XCTAssertEqual(existingVisit.dishEntryArray.count, 1)

        let deleted = try XCTUnwrap(store.deleteBeliImport(sessionID: session.id))

        XCTAssertEqual(deleted.photosDeleted, 1)
        XCTAssertEqual(deleted.dishesDeleted, 1)
        XCTAssertEqual(deleted.rankingsDeleted, 1)
        XCTAssertEqual(store.locations.map(\.id), [location.id])
        XCTAssertEqual(store.visits.map(\.id), [existingVisit.id])
        XCTAssertTrue(existingVisit.photoArray.isEmpty)
        XCTAssertTrue(existingVisit.dishEntryArray.isEmpty)
        XCTAssertTrue(store.comparisons.isEmpty)
        XCTAssertTrue(store.beliImportSessions.isEmpty)
    }

    func testDeletingImportPreservesImportedRestaurantThatLaterGainedManualActivity() throws {
        let store = AppStore(persistence: PersistenceController(inMemory: true))
        store.bootstrap(myName: "Davis")
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let ranking = BeliRankingRow(
            id: "new-restaurant", rank: 1, restaurantName: "New Cafe",
            city: "Waco, TX", createdAt: date, visitDates: []
        )
        let archive = BeliParsedArchive(
            namespace: "namespace", exportDate: date, rankings: [ranking], photos: [], dishNotes: []
        )
        let request = BeliImportRequest(
            archive: archive, resolutions: [ranking.id: .unresolved(markClosed: false)],
            photoRankingAssignments: [:], dishRankingAssignments: [:], downloadedPhotos: [:]
        )
        _ = store.importBeli(request)
        let location = try XCTUnwrap(store.locations.first)
        let importedVisitID = try XCTUnwrap(store.visits.first?.id)
        let manualVisit = store.logVisit(at: location, reaction: .loved, date: date.addingTimeInterval(86_400))
        let session = try XCTUnwrap(store.beliImportSessions.first)

        let deleted = try XCTUnwrap(store.deleteBeliImport(sessionID: session.id))

        XCTAssertEqual(deleted.restaurantsDeleted, 0)
        XCTAssertEqual(deleted.restaurantsPreserved, 1)
        XCTAssertEqual(deleted.outingsDeleted, 1)
        XCTAssertEqual(store.locations.map(\.id), [location.id])
        XCTAssertEqual(store.visits.map(\.id), [manualVisit.id])
        XCTAssertFalse(store.visits.contains { $0.id == importedVisitID })
    }

    func testPrivateBeliExportWhenProvidedLocally() throws {
        guard let path = ProcessInfo.processInfo.environment["BELI_TEST_EXPORT"] else {
            throw XCTSkip("Set BELI_TEST_EXPORT to validate a private export without committing it.")
        }
        let archive = try BeliImporter.parse(url: URL(fileURLWithPath: path))
        XCTAssertEqual(archive.rankings.count, 70)
        XCTAssertEqual(archive.knownVisitCount, 19)
        XCTAssertEqual(archive.unknownVisitCount, 51)
        XCTAssertEqual(archive.photos.count, 24)
        XCTAssertEqual(archive.dishNotes.count, 1)
    }
}
