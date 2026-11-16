import XCTest
@testable import RestaurantLog

/// The face-offs that follow a logged outing should walk the new restaurant
/// toward its place, not sample its neighbours at random.
@MainActor
final class DialInTests: XCTestCase {
    private var persistence: PersistenceController!
    private var store: AppStore!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "activeCircleID")
        UserDefaults.standard.removeObject(forKey: "devicePersonID")
        UserDefaults.standard.removeObject(forKey: "devicePersonIDsByCircle")
        persistence = PersistenceController(inMemory: true)
        store = AppStore(persistence: persistence)
        store.bootstrap(myName: "George")
    }

    private func restaurant(
        _ name: String,
        _ reaction: Reaction,
        category: DiningCategory = .fullService
    ) -> RestaurantLocation {
        let location = store.createLocation(name: name, category: category)
        store.logVisit(at: location, reaction: reaction)
        return location
    }

    func testFirstOpponentIsTheNearestScoreInTheSameCategory() {
        _ = restaurant("Loved Place", .loved)
        let fine = restaurant("Fine Place", .fine)
        _ = restaurant("Avoided Place", .notForMe)
        _ = restaurant("Fine Coffee", .fine, category: .coffeeTea)
        let logged = restaurant("Just Logged", .fine)

        XCTAssertEqual(store.dialInOpponent(for: logged)?.id, fine.id)
    }

    func testPreferringTheNewPlaceSendsTheNextQuestionUpTheRanking() {
        let loved = restaurant("Loved Place", .loved)
        let liked = restaurant("Liked Place", .liked)
        _ = restaurant("Avoided Place", .notForMe)
        let logged = restaurant("Just Logged", .fine)

        let next = store.dialInOpponent(for: logged, after: .preferred)
        XCTAssertEqual(next?.id, liked.id, "The nearest restaurant ranked above comes first")

        let afterThat = store.dialInOpponent(for: logged, excluding: [liked.id], after: .preferred)
        XCTAssertEqual(afterThat?.id, loved.id, "A restaurant already asked about is never repeated")
    }

    func testPassingOverTheNewPlaceSendsTheNextQuestionDownTheRanking() {
        _ = restaurant("Loved Place", .loved)
        let fine = restaurant("Fine Place", .fine)
        let avoided = restaurant("Avoided Place", .notForMe)
        let logged = restaurant("Just Logged", .liked)

        XCTAssertEqual(store.dialInOpponent(for: logged, after: .passedOver)?.id, fine.id)
        XCTAssertEqual(
            store.dialInOpponent(for: logged, excluding: [fine.id], after: .passedOver)?.id,
            avoided.id
        )
    }

    func testDialInEndsWhenNothingIsLeftInTheDirectionOfTravel() {
        _ = restaurant("Liked Place", .liked)
        let logged = restaurant("Just Logged", .loved)
        XCTAssertNil(
            store.dialInOpponent(for: logged, after: .preferred),
            "A restaurant preferred over everything above it has reached the top"
        )

        let bottom = restaurant("Bottom Place", .notForMe)
        XCTAssertNil(
            store.dialInOpponent(for: bottom, after: .passedOver),
            "A restaurant passed over at the bottom has nowhere further to fall"
        )
    }

    func testATieKeepsAskingAboutTheNearestRemainingNeighbour() {
        let liked = restaurant("Liked Place", .liked)
        let avoided = restaurant("Avoided Place", .notForMe)
        let logged = restaurant("Just Logged", .fine)

        XCTAssertEqual(store.dialInOpponent(for: logged, after: .tooClose)?.id, liked.id)
        XCTAssertEqual(
            store.dialInOpponent(for: logged, excluding: [liked.id], after: .tooClose)?.id,
            avoided.id
        )
    }

    func testThereIsNothingToDialInAgainstWhenTheCategoryHoldsOnlyTheNewPlace() {
        _ = restaurant("Loved Place", .loved)
        let logged = restaurant("Only Bakery", .liked, category: .bakeries)

        XCTAssertNil(store.dialInOpponent(for: logged))
    }

    func testAnAnswerMovesTheScoreAndTheDialInEndsOnceEveryoneHasBeenAsked() throws {
        let liked = restaurant("Liked Place", .liked)
        let logged = restaurant("Just Logged", .fine)
        let before = try XCTUnwrap(store.score(for: logged)).score

        store.recordComparison(a: logged, b: liked, outcome: .a)

        XCTAssertGreaterThan(try XCTUnwrap(store.score(for: logged)).score, before)
        XCTAssertNil(
            store.dialInOpponent(for: logged, excluding: [liked.id], after: .preferred),
            "With the only other restaurant already asked about, the dial-in is finished"
        )
    }
}
