import XCTest

@MainActor
final class RestaurantLogUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-resetForUITests", "-seedSampleData"]
        app.launch()
        XCTAssertTrue(
            app.buttons["log-meal-button"].waitForExistence(timeout: 12),
            "The first launch must reach usable content without terminating and reopening the app."
        )
    }

    func testSeededLogNavigatesPrimaryTabs() {
        XCTAssertTrue(app.staticTexts["app-title"].exists)
        XCTAssertTrue(app.tabBars.buttons["Log"].exists)

        app.tabBars.buttons["Rankings"].tap()
        XCTAssertTrue(app.navigationBars["Rankings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["George"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["Michelle"].exists)
        app.segmentedControls.buttons["Circle"].tap()

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Want to Try"].tap()
        XCTAssertTrue(app.navigationBars["Want to Try"].waitForExistence(timeout: 5))

        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Statistics"].exists)
        XCTAssertTrue(app.staticTexts["Backfill"].exists)
    }

    func testAppearancePreferenceChangesAndPersists() {
        openAppearanceSettings()

        let appearancePicker = app.segmentedControls["appearance-picker"]
        XCTAssertTrue(appearancePicker.waitForExistence(timeout: 3))
        appearancePicker.buttons["Dark"].tap()
        XCTAssertTrue(appearancePicker.buttons["Dark"].isSelected)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["log-meal-button"].waitForExistence(timeout: 8))
        openAppearanceSettings()

        let persistedPicker = app.segmentedControls["appearance-picker"]
        XCTAssertTrue(persistedPicker.waitForExistence(timeout: 3))
        XCTAssertTrue(persistedPicker.buttons["Dark"].isSelected)
        persistedPicker.buttons["System"].tap()
    }

    func testSettingsFooterShowsVersionAndReleaseDate() {
        openAppearanceSettings()

        let footer = app.staticTexts["app-version-footer"]
        for _ in 0..<10 where !footer.exists { app.swipeUp() }

        XCTAssertTrue(footer.waitForExistence(timeout: 3))
        XCTAssertEqual(footer.label, "Big Beautiful Restaurant Log 3.0 • Released July 28, 2026")
    }

    func testDiningAtlasShowsTheFirstVisitTrail() {
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))

        app.buttons["Open dining atlas"].tap()

        XCTAssertTrue(app.navigationBars["Dining Atlas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["9 places on the record"].exists)
        XCTAssertTrue(app.staticTexts["Normal Ice Cream"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Dining Atlas"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testManualThreeTapLogCreatesRankingPayoff() {
        app.buttons["log-meal-button"].tap()
        XCTAssertTrue(app.buttons["start-meal-with-photo"].waitForExistence(timeout: 3))
        let search = app.textFields["log-place-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Codex Test Kitchen")

        let searchKey = app.keyboards.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "search")).firstMatch
        if searchKey.waitForExistence(timeout: 2) { searchKey.tap() }

        let manual = app.buttons["manual-place-choice"]
        XCTAssertTrue(manual.waitForExistence(timeout: 4))
        manual.tap()

        let michelle = app.buttons["Michelle"]
        XCTAssertTrue(michelle.waitForExistence(timeout: 3))
        michelle.tap()

        let reaction = app.buttons["reaction-Liked It"]
        XCTAssertTrue(reaction.waitForExistence(timeout: 3))
        reaction.tap()

        XCTAssertTrue(app.scrollViews["log-payoff"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Codex Test Kitchen"].exists)
        XCTAssertTrue(app.buttons["Add Dishes, Photos & Details"].exists)
        app.buttons["Done"].tap()

        app.tabBars.buttons["History"].tap()
        let loggedVisit = app.staticTexts["Codex Test Kitchen"].firstMatch
        XCTAssertTrue(loggedVisit.waitForExistence(timeout: 6))
        loggedVisit.tap()
        XCTAssertTrue(app.staticTexts["George, Michelle"].waitForExistence(timeout: 3))
    }

    func testVisibleHomeButtonsMeetMinimumHitTarget() {
        let buttons = app.buttons.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(buttons.isEmpty)
        let undersized = buttons.compactMap { button -> String? in
            guard button.frame.width < 44 || button.frame.height < 44 else { return nil }
            return "\(button.label.isEmpty ? "Unlabeled button" : button.label): \(button.frame)"
        }
        XCTAssertEqual(undersized, [], "Every visible home button must expose at least a 44×44-point hit target")
    }

    func testDeletingVisitReturnsToHistoryWithoutCrashing() {
        app.tabBars.buttons["History"].tap()
        let visit = app.staticTexts["The Copper Onion"].firstMatch
        XCTAssertTrue(visit.waitForExistence(timeout: 5))
        visit.tap()

        let deleteButton = app.buttons["Delete Entire Outing"]
        for _ in 0..<8 where !deleteButton.isHittable { app.swipeUp() }
        XCTAssertTrue(deleteButton.isHittable)
        deleteButton.tap()
        app.sheets.buttons["Delete Outing"].tap()

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
    }

    func testRemovingWantedRestaurantDoesNotCrash() {
        app.tabBars.buttons["Want to Try"].tap()
        app.buttons["Add a Place"].tap()

        let restaurant = app.staticTexts["The Copper Onion"].firstMatch
        XCTAssertTrue(restaurant.waitForExistence(timeout: 5))
        restaurant.tap()
        XCTAssertTrue(restaurant.waitForExistence(timeout: 5))

        restaurant.press(forDuration: 1)
        app.buttons["Remove from Want to Try"].tap()

        XCTAssertTrue(app.staticTexts["Nothing saved yet"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testResetAppReturnsToOnboarding() {
        app.tabBars.buttons["More"].tap()
        app.staticTexts["Settings & Privacy"].tap()

        let resetButton = app.buttons["reset-app-button"]
        for _ in 0..<6 where !resetButton.exists { app.swipeUp() }
        XCTAssertTrue(resetButton.waitForExistence(timeout: 3))
        for _ in 0..<6 where !resetButton.isHittable { app.swipeUp() }
        XCTAssertTrue(resetButton.isHittable)
        resetButton.tap()
        app.alerts.buttons["Erase Everything"].tap()

        XCTAssertTrue(app.buttons["Get Started"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }

    func testOnboardingSupportingTextWrapsAtAccessibilitySize() {
        app.terminate()
        app.launchArguments = [
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
        XCTAssertEqual(detail.label, "Start with your identity. You can add and tag anyone in your circle when you log visits.")
        XCTAssertFalse(app.textFields["Partner (optional)"].exists)

        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
        for _ in 0..<4 where !continueButton.isHittable { app.swipeUp() }
        XCTAssertTrue(continueButton.isHittable, "The scrollable step should keep its action reachable at large text sizes")
    }

    func testOnboardingBackupRestoreRequiresDestructiveConfirmation() {
        app.terminate()
        app.launchArguments = [
            "-resetForUITests",
            "-didCompleteGrandOpening", "NO"
        ]
        app.launch()

        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 8))
        getStarted.tap()

        let nameField = app.textFields["Your name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tap()
        nameField.typeText("Backup Tester")
        let continueButton = app.buttons["Continue"]
        for _ in 0..<4 where !continueButton.isHittable { app.swipeUp() }
        continueButton.tap()

        let restoreAction = app.staticTexts["Restore a Full Backup"]
        XCTAssertTrue(restoreAction.waitForExistence(timeout: 3))
        restoreAction.tap()

        XCTAssertTrue(app.sheets.staticTexts["Restore from backup?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.sheets.buttons["Choose Backup and Replace Everything"].exists)
        XCTAssertTrue(app.sheets.buttons["Cancel"].exists)
    }

    private func openAppearanceSettings() {
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
        app.staticTexts["Settings & Privacy"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }
}
