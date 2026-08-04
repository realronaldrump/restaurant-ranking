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
        XCTAssertEqual(archive.rankings[0].visitDateKeys, ["2025-10-08", "2025-11-02"])
        XCTAssertEqual(archive.rankings[0].visitDateTimeZoneOffsetSeconds.count, 2)
        XCTAssertEqual(archive.photos.first?.uploadTimeZoneOffsetSeconds, 0)
        XCTAssertEqual(archive.dishNotes.first?.createdAtTimeZoneOffsetSeconds, 0)
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

    func testParseFilesRejectsCSVLargerThanThePreflightLimit() {
        let oversized = Data(repeating: UInt8(ascii: "x"), count: Int(BeliImporter.maximumCSVBytes) + 1)

        XCTAssertThrowsError(try BeliImporter.parse(files: ["rankings.csv": oversized])) { error in
            XCTAssertEqual(error as? BeliImporter.ImportError, .oversizedEntry("rankings.csv"))
        }
    }

    func testRejectsMoreVisitDatesThanOneRankingCanSafelyExpand() {
        let visits = (0...BeliImporter.maximumVisitDatesPerRanking)
            .map { "datetime.date(2025, 1, \(($0 % 28) + 1))" }
            .joined(separator: ", ")
        let rankings = """
        Rank,Restaurant Name,City,Created Date,Visit Dates
        1,Place,City,2025-01-01 00:00:00+00:00,"[\(visits)]"
        """

        XCTAssertThrowsError(try BeliImporter.parse(files: ["rankings.csv": Data(rankings.utf8)])) { error in
            XCTAssertEqual(
                error as? BeliImporter.ImportError,
                .invalidRow(file: "rankings.csv", row: 2, detail: "Visit Dates contains too many dates.")
            )
        }
    }

    func testRejectsArchiveWhoseRowsExpandBeyondTheTotalOutingLimit() {
        let visits = (0..<BeliImporter.maximumVisitDatesPerRanking)
            .map { "datetime.date(2025, 1, \(($0 % 28) + 1))" }
            .joined(separator: ", ")
        let rowCount = (BeliImporter.maximumTotalOutings / BeliImporter.maximumVisitDatesPerRanking) + 1
        let rows = (1...rowCount).map {
            "\($0),Place \($0),City,2025-01-01 00:00:00+00:00,\"[\(visits)]\""
        }
        let rankings = (["Rank,Restaurant Name,City,Created Date,Visit Dates"] + rows).joined(separator: "\n")

        XCTAssertThrowsError(try BeliImporter.parse(files: ["rankings.csv": Data(rankings.utf8)])) { error in
            XCTAssertEqual(error as? BeliImporter.ImportError, .tooManyOutings)
        }
    }

    func testPhotoDownloaderStopsFetchingAfterRetainedDataReachesItsLimit() async throws {
        let tracker = DownloadConcurrencyTracker()
        let rows = try (0..<8).map { index in
            BeliPhotoRow(
                id: "photo-\(index)", restaurantName: "Place", city: "City",
                caption: nil, isFavoriteDish: false, uploadDate: .now,
                imageURL: try XCTUnwrap(URL(string: "https://example.com/\(index).jpg"))
            )
        }
        let limits = BeliPhotoDownloader.Limits(
            maximumConcurrentDownloads: 2,
            maximumResponseBytes: 32,
            maximumPreparedPhotoBytes: 8,
            maximumRetainedPhotoCount: 8,
            maximumRetainedPreparedBytes: 10
        )

        let result = await BeliPhotoDownloader.download(rows, maxConcurrent: 100, limits: limits) { row, _ in
            await tracker.started()
            try? await Task.sleep(for: .milliseconds(20))
            await tracker.finished()
            let photo = BackfillPhoto(
                id: UUID(), fullData: Data(repeating: 1, count: 4), thumbnailData: Data(repeating: 2, count: 2),
                date: row.uploadDate, coordinate: nil, captureDate: nil
            )
            return .success(.init(row: row, photo: photo, contentHash: row.id))
        }

        let peak = await tracker.peak
        let totalStarted = await tracker.totalStarted
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(totalStarted, 2)
        XCTAssertEqual(result.photos.count, 1)
        XCTAssertEqual(result.failures.count, 7)
        XCTAssertTrue(result.failures.values.allSatisfy { $0.contains("memory limit") })
    }

    func testDownloadedFileValidationRejectsOversizedBodyBeforeLoadingIt() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 7, count: 9).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(URL(string: "https://example.com/final.jpg")),
            statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"]
        ))
        let limits = BeliPhotoDownloader.Limits(
            maximumConcurrentDownloads: 1,
            maximumResponseBytes: 8,
            maximumPreparedPhotoBytes: 8,
            maximumRetainedPhotoCount: 1,
            maximumRetainedPreparedBytes: 8
        )

        XCTAssertThrowsError(try BeliPhotoDownloader.loadDownloadedFile(file, response: response, limits: limits)) { error in
            XCTAssertEqual(error as? BeliPhotoDownloader.DownloadError, .responseTooLarge)
        }
    }

    func testDownloadedFileValidationRejectsNonHTTPSRedirectDestination() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(URL(string: "http://example.com/final.jpg")),
            statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"]
        ))

        XCTAssertThrowsError(
            try BeliPhotoDownloader.loadDownloadedFile(file, response: response, limits: .default)
        ) { error in
            XCTAssertEqual(error as? BeliPhotoDownloader.DownloadError, .insecureRedirect)
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

    func testReimportDownloadsOnlyPhotosThatAreStillMissing() throws {
        let store = AppStore(persistence: PersistenceController(inMemory: true))
        store.bootstrap(myName: "Davis")
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let ranking = BeliRankingRow(
            id: "restaurant-key", rank: 1, restaurantName: "Resume Cafe",
            city: "Waco, TX", createdAt: date, visitDates: []
        )
        let photoRows = try (0..<2).map { index in
            BeliPhotoRow(
                id: "photo-\(index)", restaurantName: ranking.restaurantName, city: ranking.city,
                caption: nil, isFavoriteDish: false,
                uploadDate: date.addingTimeInterval(Double(index)),
                imageURL: try XCTUnwrap(URL(string: "https://example.com/\(index).jpg"))
            )
        }
        let archive = BeliParsedArchive(
            namespace: "namespace", exportDate: date,
            rankings: [ranking], photos: photoRows, dishNotes: []
        )
        func downloaded(_ row: BeliPhotoRow) -> BeliDownloadedPhoto {
            BeliDownloadedPhoto(
                row: row,
                photo: BackfillPhoto(
                    id: UUID(), fullData: Data([1, 2, 3]), thumbnailData: Data([1]),
                    date: date, coordinate: nil, captureDate: nil
                ),
                contentHash: row.id
            )
        }
        func request(with photos: [String: BeliDownloadedPhoto]) -> BeliImportRequest {
            BeliImportRequest(
                archive: archive,
                resolutions: [ranking.id: .unresolved(markClosed: false)],
                photoRankingAssignments: [:],
                dishRankingAssignments: [:],
                downloadedPhotos: photos
            )
        }

        _ = store.importBeli(request(with: [photoRows[0].id: downloaded(photoRows[0])]))

        XCTAssertEqual(store.beliPhotosNeedingDownload(from: archive).map(\.id), [photoRows[1].id])

        _ = store.importBeli(request(with: [photoRows[1].id: downloaded(photoRows[1])]))

        XCTAssertTrue(store.beliPhotosNeedingDownload(from: archive).isEmpty)
        XCTAssertEqual(store.visits.first?.photoArray.count, 2)

        let deletedPhoto = try XCTUnwrap(store.visits.first?.photoArray.first)
        XCTAssertTrue(store.deletePhoto(deletedPhoto))
        XCTAssertEqual(store.beliPhotosNeedingDownload(from: archive).map(\.id), [photoRows[0].id])

        _ = store.importBeli(request(with: [photoRows[0].id: downloaded(photoRows[0])]))

        XCTAssertTrue(store.beliPhotosNeedingDownload(from: archive).isEmpty)
        XCTAssertEqual(store.visits.first?.photoArray.count, 2)
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

    func testDiningAreaResolverMergesBareCityWithItsOnlyQualifiedVariant() throws {
        let bare = areaEvidence(city: "Waco", restaurant: "Cafe Homestead", outings: 35)
        let qualified = areaEvidence(city: "Waco, TX", restaurant: "Harvest on 25th", outings: 11)

        let resolved = DiningAreaResolver.resolve([bare, qualified])

        XCTAssertEqual(try XCTUnwrap(resolved[bare.id]), resolved[qualified.id])
        XCTAssertEqual(resolved[bare.id]?.name, "Waco, TX")
    }

    func testDiningAreaResolverMergesAdministrativeLongForm() throws {
        let short = areaEvidence(city: "Redstone", restaurant: "Propaganda Pie", outings: 1)
        let long = areaEvidence(
            city: "Redstone Historic District, CO",
            restaurant: "Propaganda Pie",
            sourceIdentifier: "maps:propaganda-pie",
            outings: 1
        )

        let resolved = DiningAreaResolver.resolve([short, long])

        XCTAssertEqual(try XCTUnwrap(resolved[short.id]), resolved[long.id])
        XCTAssertEqual(resolved[short.id]?.name, "Redstone Historic District, CO")
    }

    func testDiningAreaResolverCanonicalizesPunctuatedRegionAbbreviations() throws {
        let dotted = areaEvidence(city: "Washington, D.C.", restaurant: "Capitol Table")
        let compact = areaEvidence(city: "Washington, DC", restaurant: "Monument Cafe")
        let unseparated = areaEvidence(city: "Washington D.C.", restaurant: "Federal Grill")
        let named = areaEvidence(city: "Washington, District of Columbia", restaurant: "Mall Bistro")

        let resolved = DiningAreaResolver.resolve([dotted, compact, unseparated, named])

        XCTAssertEqual(try XCTUnwrap(resolved[dotted.id]), resolved[compact.id])
        XCTAssertEqual(resolved[dotted.id], resolved[unseparated.id])
        XCTAssertEqual(resolved[dotted.id], resolved[named.id])
        XCTAssertEqual(resolved[dotted.id]?.id, "area:washington|dc")
    }

    func testDiningAreaResolverKeepsAmbiguousRegionsSeparate() throws {
        let bare = areaEvidence(city: "Springfield", restaurant: "Corner Cafe")
        let illinois = areaEvidence(city: "Springfield, IL", restaurant: "Prairie Table")
        let missouri = areaEvidence(city: "Springfield, MO", restaurant: "Ozark Table")

        let resolved = DiningAreaResolver.resolve([bare, illinois, missouri])

        XCTAssertNotEqual(try XCTUnwrap(resolved[bare.id]), resolved[illinois.id])
        XCTAssertNotEqual(resolved[bare.id], resolved[missouri.id])
        XCTAssertNotEqual(resolved[illinois.id], resolved[missouri.id])
    }

    func testDiningAreaResolverUsesPlaceEvidenceForMinorCityTypo() throws {
        let correct = areaEvidence(
            city: "Albuquerque, NM", restaurant: "Mesa Provisions",
            latitude: 35.0844, longitude: -106.6504
        )
        let typo = areaEvidence(
            city: "Albuqurque", restaurant: "Mesa Provisions",
            latitude: 35.0845, longitude: -106.6505
        )

        let resolved = DiningAreaResolver.resolve([correct, typo])

        XCTAssertEqual(try XCTUnwrap(resolved[correct.id]), resolved[typo.id])
        XCTAssertEqual(resolved[typo.id]?.name, "Albuquerque, NM")
    }

    func testDiningAreaResolverDoesNotFuzzyMergeWithoutPlaceEvidence() throws {
        let correct = areaEvidence(city: "Albuquerque, NM", restaurant: "Mesa Provisions")
        let typo = areaEvidence(city: "Albuqurque", restaurant: "Different Restaurant")
        let chainInAnotherCity = areaEvidence(city: "Santa Fe, NM", restaurant: "Mesa Provisions")

        let resolved = DiningAreaResolver.resolve([correct, typo, chainInAnotherCity])

        XCTAssertNotEqual(try XCTUnwrap(resolved[correct.id]), resolved[typo.id])
        XCTAssertNotEqual(resolved[correct.id], resolved[chainInAnotherCity.id])
    }

    func testDiningAreaResolverDoesNotMergeNearbyBranchesOfTheSameChain() throws {
        let first = areaEvidence(
            city: "Greenville, TX", restaurant: "Corner Coffee",
            latitude: 33.1385, longitude: -96.1108
        )
        let second = areaEvidence(
            city: "Greenvile", restaurant: "Corner Coffee",
            latitude: 33.1430, longitude: -96.1108
        )

        let resolved = DiningAreaResolver.resolve([first, second])

        XCTAssertNotEqual(try XCTUnwrap(resolved[first.id]), resolved[second.id])
    }

    private func areaEvidence(
        city: String,
        restaurant: String,
        address: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        sourceIdentifier: String? = nil,
        outings: Int = 1
    ) -> DiningAreaEvidence {
        DiningAreaEvidence(
            id: UUID(),
            city: city,
            restaurantName: restaurant,
            address: address,
            latitude: latitude,
            longitude: longitude,
            sourceIdentifier: sourceIdentifier,
            outingCount: outings
        )
    }
}

private actor DownloadConcurrencyTracker {
    private var active = 0
    private(set) var peak = 0
    private(set) var totalStarted = 0

    func started() {
        active += 1
        totalStarted += 1
        peak = max(peak, active)
    }

    func finished() {
        active -= 1
    }
}
