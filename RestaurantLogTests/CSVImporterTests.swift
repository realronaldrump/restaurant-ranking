import XCTest
@testable import RestaurantLog

final class CSVImporterTests: XCTestCase {
    func testFlexibleCSVWithQuotedCommaAndScore() throws {
        let csv = "Restaurant,Date,Score,Cuisine,Notes\n\"Cafe, Central\",2025-03-14,8.7,Coffee,\"Birthday, after the show\"\n"
        let result = try CSVImporter.parse(data: Data(csv.utf8))
        XCTAssertEqual(result.meals.count, 1)
        XCTAssertEqual(result.meals[0].establishment, "Cafe, Central")
        XCTAssertEqual(result.meals[0].reaction, .loved)
        XCTAssertEqual(result.meals[0].memory, "Birthday, after the show")
    }

    func testEscapedQuotesArePreserved() {
        let rows = CSVImporter.parseRows("Name,Note\nPlace,\"The \"\"best\"\" patio\"\n")
        XCTAssertEqual(rows[1][1], "The \"best\" patio")
    }
}
