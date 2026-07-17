import XCTest

final class BigBeautifulUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-disableCloudKit", "-resetForUITests", "-seedSampleData"]
        app.launch()
        XCTAssertTrue(app.buttons["log-meal-button"].waitForExistence(timeout: 8))
    }

    func testSeededLedgerNavigatesPrimaryTabs() {
        XCTAssertTrue(app.staticTexts["app-title"].exists)

        app.tabBars.buttons["Rankings"].tap()
        XCTAssertTrue(app.navigationBars["Rankings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.segmentedControls.buttons["Davis"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["Kelsey"].exists)
        app.segmentedControls.buttons["Us"].tap()

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))

        app.tabBars.buttons["Want to Try"].tap()
        XCTAssertTrue(app.navigationBars["Want to Try"].waitForExistence(timeout: 3))

        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Statistics"].exists)
        XCTAssertTrue(app.staticTexts["Backfill"].exists)
    }

    func testManualThreeTapLogCreatesRankingPayoff() {
        app.buttons["log-meal-button"].tap()
        let search = app.textFields["log-place-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Codex Test Kitchen")

        let searchKey = app.keyboards.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "search")).firstMatch
        if searchKey.waitForExistence(timeout: 2) { searchKey.tap() }

        let manual = app.buttons["manual-place-choice"]
        XCTAssertTrue(manual.waitForExistence(timeout: 4))
        manual.tap()

        let reaction = app.buttons["reaction-Liked It"]
        XCTAssertTrue(reaction.waitForExistence(timeout: 3))
        reaction.tap()

        XCTAssertTrue(app.scrollViews["log-payoff"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Codex Test Kitchen"].exists)
        XCTAssertTrue(app.buttons["Add Dishes, Photos & Details"].exists)
        app.buttons["Done"].tap()

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Codex Test Kitchen"].waitForExistence(timeout: 3))
    }

    func testVisibleHomeButtonsMeetMinimumHitTarget() {
        let buttons = app.buttons.allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertFalse(buttons.isEmpty)
        let undersized = buttons.compactMap { button -> String? in
            guard button.frame.width < 44 || button.frame.height < 44 else { return nil }
            return "\(button.label.isEmpty ? "Unlabeled button" : button.label): \(button.frame)"
        }
        XCTAssertEqual(undersized, [], "Every visible home button must expose at least a 44×44-point hit target")
    }

    func testOnboardingSupportingTextWrapsAtAccessibilitySize() {
        app.terminate()
        app.launchArguments = [
            "-disableCloudKit",
            "-resetForUITests",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraLarge"
        ]
        app.launch()

        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 8))
        getStarted.tap()

        let detail = app.staticTexts["onboarding-step-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        XCTAssertEqual(detail.label, "Rankings stay personal. Shared visits appear for everyone in your circle.")
        XCTAssertGreaterThan(detail.frame.height, 44, "Onboarding supporting copy should occupy multiple lines instead of truncating")

        let continueButton = app.buttons["Continue"]
        if !continueButton.isHittable { app.swipeUp() }
        XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
        XCTAssertTrue(continueButton.isHittable, "The scrollable step should keep its action reachable at large text sizes")
    }
}
