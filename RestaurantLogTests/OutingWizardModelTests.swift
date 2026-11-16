import XCTest
@testable import RestaurantLog

@MainActor
final class OutingWizardModelTests: XCTestCase {
    private var persistence: PersistenceController!
    private var store: AppStore!
    private var wizard: OutingWizardModel!

    override func setUp() async throws {
        for key in ["activeCircleID", "devicePersonID", "devicePersonIDsByCircle"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        persistence = PersistenceController(inMemory: true)
        store = AppStore(persistence: persistence)
        store.bootstrap(myName: "Review")
        wizard = OutingWizardModel(store: store, locationService: LocationService())
        wizard.start()
    }

    private func saveNew(_ name: String = "New Review Place") throws -> VisitEntity {
        wizard.query = name
        wizard.select(wizard.manualChoice)
        wizard.beginReaction(.liked)
        XCTAssertEqual(wizard.commitPendingReaction(), .saved)
        return try XCTUnwrap(wizard.savedVisit)
    }

    func testWizardHappyPathAndUndo() throws {
        let peer = store.createLocation(name: "Peer", category: .fullService)
        store.logVisit(at: peer, reaction: .liked)
        let visit = try saveNew()
        wizard.answer("yes", for: .goBack)
        wizard.answer(Reaction.loved.rawValue, for: .value)
        wizard.addDish(named: "Soup")
        let person = try XCTUnwrap(wizard.savedPersonID)
        XCTAssertEqual(visit.rating(for: person)?.value, .loved)
        XCTAssertEqual(wizard.dishEntries.count, 1)
        wizard.skipToRanking()
        XCTAssertNotNil(wizard.activeOpponent)
        wizard.settle(.a)
        XCTAssertEqual(store.comparisons.count, 1)
        wizard.undoSave()
        XCTAssertFalse(visit.isAlive)
        XCTAssertEqual(store.locations.map(\.id), [peer.id])
        XCTAssertTrue(store.comparisons.isEmpty)
    }

    func testWizardMovePreservesPreexistingDestination() throws {
        let wanted = store.createLocation(name: "Existing Wanted", category: .fullService)
        store.toggleWant(wanted)
        let visit = try saveNew()
        wizard.select(wanted.placeChoice)
        XCTAssertEqual(visit.location, wanted)
        wizard.query = "Third Place"
        wizard.select(wizard.manualChoice)
        XCTAssertTrue(wanted.isAlive)
        XCTAssertTrue(store.isWanted(wanted))
    }

    func testEditorMoveThenWizardMoveMustPreservePreexistingDestination() throws {
        let wanted = store.createLocation(name: "Existing Wanted", category: .fullService)
        let wantedID = wanted.id
        store.toggleWant(wanted)
        store.recordAnchor(for: wanted, value: 74)
        let visit = try saveNew()
        wizard.skipToRanking()
        wizard.willOpenEditor()
        store.changeLocation(of: visit, to: wanted)
        wizard.reconcileRanking()
        wizard.back()
        wizard.go(to: .place)
        wizard.query = "Third Place"
        wizard.select(wizard.manualChoice)
        XCTAssertTrue(store.locations.contains { $0.id == wantedID }, "Moving an outing must not erase a restaurant created before this wizard")
        XCTAssertTrue(store.wantEntries.contains { $0.location?.id == wantedID }, "Want to Try entry must survive")
        XCTAssertTrue(store.comparisons.contains { $0.locationAID == wantedID }, "Existing ranking evidence must survive")
    }

    func testDateReflectsEditorChange() throws {
        let visit = try saveNew()
        wizard.willOpenEditor()
        let older = Date.now.addingTimeInterval(-45 * 86_400)
        store.updateVisitDate(visit, date: older)
        wizard.edit(.reaction)
        XCTAssertEqual(wizard.visitDate, visit.date, "The date displayed after reopening an answer must match the saved outing")
        XCTAssertTrue(wizard.steps.contains(.clarity), "A 45-day-old outing should ask about memory clarity")
    }

    func testRepeatOutingScoreReflectsSavedDetails() throws {
        store.seedSampleLog()
        let location = try XCTUnwrap(store.locations.first { $0.name == "Yoko Ramen" })
        wizard.select(location.placeChoice)
        wizard.beginReaction(.liked)
        XCTAssertEqual(wizard.commitPendingReaction(), .saved)
        let before = try XCTUnwrap(wizard.score)
        let visit = try XCTUnwrap(wizard.savedVisit)
        let personID = try XCTUnwrap(wizard.savedPersonID)
        let rating = try XCTUnwrap(visit.rating(for: personID))
        store.updateRating(rating, service: .loved, atmosphere: .loved, value: .loved, personID: personID)
        let after = try XCTUnwrap(wizard.score)
        XCTAssertGreaterThan(after.score, before.score)
    }

    func testCompanionTogglePreservesEditorChanges() throws {
        let bob = try XCTUnwrap(store.addNamedCompanion(name: "Bob"))
        let cara = try XCTUnwrap(store.addNamedCompanion(name: "Cara"))
        let visit = try saveNew()
        wizard.willOpenEditor()
        store.updateVisit(visit, type: nil, priceBand: 0, occasion: nil, memory: nil, companions: [bob.id])
        wizard.edit(.reaction)
        wizard.toggleCompanion(cara.id)
        XCTAssertEqual(Set(visit.companionIDs), Set([bob.id, cara.id]), "Adding Cara must not remove Bob, who was just added in the editor")
    }

    func testEditorRestaurantCorrectionRemovesWrongRestaurantFaceOffs() throws {
        let peer = store.createLocation(name: "Peer", category: .fullService)
        store.logVisit(at: peer, reaction: .liked)
        let visit = try saveNew()
        wizard.skipToRanking()
        wizard.settle(.a)
        XCTAssertEqual(store.comparisons.count, 1)
        wizard.willOpenEditor()
        let correct = store.createLocation(name: "Correct Place", category: .dessert)
        store.changeLocation(of: visit, to: correct)
        wizard.reconcileRanking()
        XCTAssertTrue(store.comparisons.isEmpty, "Wrong-restaurant face-offs should be removed just as they are for the wizard's own relocate action")
    }
}

extension OutingWizardModelTests {
    func testRemovePhotoAfterSavingActuallyRemovesIt() throws {
        let photo = BackfillPhoto(
            id: UUID(), fullData: Data([1, 2, 3]), thumbnailData: nil, date: .now, coordinate: nil
        )
        wizard.applyPhoto(photo)
        let visit = try saveNew()
        XCTAssertEqual(visit.photoArray.count, 1)
        wizard.go(to: .place)
        wizard.clearPhoto()
        XCTAssertNil(wizard.mealPhoto)
        XCTAssertTrue(visit.photoArray.isEmpty, "Remove photo must remove the photo from the saved outing, not just hide its draft thumbnail")
    }

    func testReplacingPhotoPreservesEditorAttachmentsAndPersistsCaptureDate() throws {
        let first = BackfillPhoto(id: UUID(), fullData: Data([1]), thumbnailData: nil, date: .now, coordinate: nil)
        XCTAssertTrue(wizard.applyPhoto(first))
        let visit = try saveNew()
        let originalID = try XCTUnwrap(visit.photoArray.first?.id)
        store.addPhoto(fullData: Data([2]), thumbnailData: nil, to: visit)
        let editorPhotoID = try XCTUnwrap(visit.photoArray.first { $0.id != originalID }?.id)

        let captureDate = Date.now.addingTimeInterval(-45 * 86_400)
        let replacement = BackfillPhoto(
            id: UUID(), fullData: Data([3]), thumbnailData: nil, date: captureDate, coordinate: nil,
            captureDate: captureDate, captureTimeZoneOffsetSeconds: -7 * 3600
        )
        XCTAssertTrue(wizard.applyPhoto(replacement))
        XCTAssertEqual(visit.photoArray.count, 2)
        XCTAssertFalse(visit.photoArray.contains { $0.id == originalID })
        XCTAssertTrue(visit.photoArray.contains { $0.id == editorPhotoID })
        XCTAssertEqual(wizard.visitDate, captureDate)
        XCTAssertEqual(wizard.visitTimeZoneOffsetSeconds, -7 * 3600)
        XCTAssertTrue(wizard.steps.contains(.clarity))

        wizard.clearPhoto()
        XCTAssertEqual(visit.photoArray.map(\.id), [editorPhotoID])
        XCTAssertEqual(visit.date, captureDate, "Removing an attachment must not reset a saved outing's date.")
        store.reload()
        XCTAssertEqual(visit.photoArray.map(\.id), [editorPhotoID])
    }

    func testPhotoDeletedInEditorDisappearsFromWizard() throws {
        let photo = BackfillPhoto(id: UUID(), fullData: Data([1]), thumbnailData: nil, date: .now, coordinate: nil)
        XCTAssertTrue(wizard.applyPhoto(photo))
        let visit = try saveNew()
        let attached = try XCTUnwrap(visit.photoArray.first)
        store.deletePhoto(attached)
        XCTAssertNil(wizard.mealPhoto)
    }

    func testRestaurantCorrectionPreservesUnrelatedRankingAnswers() throws {
        let first = store.createLocation(name: "First", category: .fullService)
        let second = store.createLocation(name: "Second", category: .fullService)
        store.logVisit(at: first, reaction: .liked)
        store.logVisit(at: second, reaction: .liked)
        let unrelatedID = try XCTUnwrap(store.recordComparison(a: first, b: second, outcome: .a))
        let visit = try saveNew()
        wizard.skipToRanking()
        wizard.settle(.tie)
        let destination = store.createLocation(name: "Correct", category: .dessert)
        store.changeLocation(of: visit, to: destination)
        wizard.reconcileRanking()
        XCTAssertEqual(store.comparisons.map(\.id), [unrelatedID])
        XCTAssertEqual(wizard.loggedLocation, destination)
        XCTAssertNil(wizard.scoreBefore)
    }
}
